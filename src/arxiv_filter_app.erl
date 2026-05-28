%%%-------------------------------------------------------------------
%%% @doc arXiv preprint search agent.
%%%
%%% Queries the arXiv Atom API for papers matching a search term and
%%% returns embryos with the paper URL, title, and summary.
%%%
%%% The API returns Atom XML; this module parses it with lightweight
%%% string/regex operations rather than a full XML library to keep the
%%% dependency footprint minimal.
%%%
%%% Deduplication by URL is handled upstream by the Emquest pipeline.
%%%
%%% === Capability cascade ===
%%%
%%%   base_capabilities/0 extends em_filter:base_capabilities().
%%%
%%% Handler contract: handle/2 (Body, Memory) -> {RawList, Memory}.
%%% @end
%%%-------------------------------------------------------------------
-module(arxiv_filter_app).
-behaviour(application).

-export([start/2, stop/1]).
-export([handle/2, base_capabilities/0]).

-define(SEARCH_URL,
    "http://export.arxiv.org/api/query"
    "?max_results=10&search_query=all:").

%%====================================================================
%% Capability cascade
%%====================================================================

-spec base_capabilities() -> [binary()].
base_capabilities() ->
    em_filter:base_capabilities() ++ [<<"arxiv">>, <<"science">>,
                                      <<"papers">>, <<"preprints">>,
                                      <<"research">>].

%%====================================================================
%% Application lifecycle
%%====================================================================

start(_Type, _Args) ->
    case arxiv_filter_sup:start_link() of
        {ok, Pid} ->
            ok = start_pop_and_http(),
            {ok, Pid};
        Error ->
            Error
    end.

stop(_State) ->
    catch cowboy:stop_listener(arxiv_filter_query_listener),
    catch em_pop_sup:stop_node(arxiv_filter),
    ok.

%%====================================================================
%% Internal
%%====================================================================

start_pop_and_http() ->
    PopPort   = application:get_env(arxiv_filter, pop_port,   9406),
    QueryPort = application:get_env(arxiv_filter, query_port, 9407),
    Seeds     = application:get_env(arxiv_filter, pop_seeds,  []),
    Vec = em_filter_vec:from_capabilities(base_capabilities()),
    catch em_pop_sup:stop_node(arxiv_filter),
    catch cowboy:stop_listener(arxiv_filter_query_listener),
    {ok, PopPid} = em_pop_sup:start_node(arxiv_filter, #{
        port            => PopPort,
        query_port      => QueryPort,
        vector          => Vec,
        max_peers       => 100,
        gossip_interval => 5_000
    }),
    lists:foreach(
        fun({H, P}) -> catch em_pop_node:add_peer(PopPid, H, P) end,
        Seeds),
    Dispatch = cowboy_router:compile([
        {'_', [{"/agent/query", em_filter_http,
                #{server => arxiv_filter_server}}]}
    ]),
    {ok, _} = cowboy:start_clear(arxiv_filter_query_listener,
                                  [{port, QueryPort}],
                                  #{env => #{dispatch => Dispatch}}),
    logger:notice("[arxiv_filter] gossip port ~w  query port ~w",
                  [PopPort, QueryPort]),
    ok.

handle(Body, Memory) when is_binary(Body) ->
    {generate_embryo_list(Body), Memory};
handle(_Body, Memory) ->
    {[], Memory}.

%%====================================================================
%% Search and processing
%%====================================================================

generate_embryo_list(JsonBinary) ->
    {Query, Timeout} = extract_params(JsonBinary),
    fetch_results(Query, Timeout).

extract_params(JsonBinary) ->
    try json:decode(JsonBinary) of
        Map when is_map(Map) ->
            Query   = binary_to_list(maps:get(<<"value">>, Map,
                          maps:get(<<"query">>, Map, <<"">>))),
            Timeout = case maps:get(<<"timeout">>, Map, undefined) of
                undefined            -> 15;
                T when is_integer(T) -> T;
                T when is_binary(T)  -> binary_to_integer(T)
            end,
            {Query, Timeout};
        _ ->
            {binary_to_list(JsonBinary), 15}
    catch
        _:_ -> {binary_to_list(JsonBinary), 15}
    end.

fetch_results("", _) -> [];
fetch_results(Query, Timeout) ->
    Url = lists:flatten(io_lib:format("~s~s", [?SEARCH_URL, uri_string:quote(Query)])),
    Headers = [{"User-Agent", "arxiv_filter/1.0"}],
    case httpc:request(get, {Url, Headers},
                       [{timeout, Timeout * 1000},
                        {ssl, [{verify, verify_none}]}],
                       [{body_format, binary}]) of
        {ok, {{_, 200, _}, _, Body}} ->
            parse_atom(binary_to_list(Body));
        _ ->
            []
    end.

%%====================================================================
%% Atom XML parsing (lightweight, no xmerl dependency)
%%====================================================================

parse_atom(Xml) ->
    Entries = split_entries(Xml),
    lists:filtermap(fun parse_entry/1, Entries).

split_entries(Xml) ->
    case re:split(Xml, "<entry>", [{return, list}]) of
        [_ | Parts] -> Parts;
        _           -> []
    end.

parse_entry(EntryXml) ->
    Title   = extract_tag("title",   EntryXml),
    Id      = extract_tag("id",      EntryXml),
    Summary = extract_tag("summary", EntryXml),
    case {Title, Id} of
        {undefined, _} -> false;
        {_, undefined} -> false;
        _ ->
            Url    = normalize_url(Id),
            Resume = clean_text(Summary),
            {true, #{
                <<"properties">> => #{
                    <<"url">>    => list_to_binary(Url),
                    <<"resume">> => list_to_binary(Resume),
                    <<"title">>  => list_to_binary(clean_text(Title)),
                    <<"source">> => <<"arxiv.org">>
                }
            }}
    end.

extract_tag(Tag, Xml) ->
    Pattern = "<" ++ Tag ++ "[^>]*>([\\s\\S]*?)</" ++ Tag ++ ">",
    case re:run(Xml, Pattern, [{capture, all_but_first, list}]) of
        {match, [Content | _]} -> Content;
        _                      -> undefined
    end.

normalize_url("http://arxiv.org/abs/" ++ Rest) ->
    "https://arxiv.org/abs/" ++ Rest;
normalize_url(Url) ->
    Url.

clean_text(undefined) -> "";
clean_text(Text) ->
    L1 = re:replace(Text, "\\s+", " ", [global, {return, list}]),
    string:trim(L1).
