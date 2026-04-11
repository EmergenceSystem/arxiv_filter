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
%% Application behaviour
%%====================================================================

start(_Type, _Args) ->
    em_filter:start_agent(arxiv_filter, ?MODULE, #{
        capabilities => base_capabilities()
    }),
    {ok, self()}.

stop(_State) ->
    em_filter:stop_agent(arxiv_filter).

%%====================================================================
%% Agent handler
%%====================================================================

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
