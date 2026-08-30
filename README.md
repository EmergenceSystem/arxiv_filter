# arxiv_filter

EmergenceSystem filter that searches arXiv and returns scientific preprints as embryos.


<!-- emergence-context -->
Part of **[EmergenceSystem](https://github.com/EmergenceSystem)** — a distributed
discovery network of small, single-source agents. This filter joins the em_pop gossip
mesh and answers `POST /agent/query`; Emquest fans each query out to many filters in
parallel and aggregates the results.

## API

Queries the [arXiv API](http://export.arxiv.org/api/query) Atom feed. Free, no API key required.

## Input

```json
{"query": "transformer neural network"}
```

| Field     | Type    | Default | Description              |
|-----------|---------|---------|--------------------------|
| `query`   | string  | —       | Search term              |
| `value`   | string  | —       | Alias for `query`        |
| `timeout` | integer | `15`    | HTTP timeout in seconds  |

## Output

Up to 10 embryos per query, one per paper:

```json
{
  "properties": {
    "url":    "https://arxiv.org/abs/1706.03762",
    "resume": "We propose a new simple network architecture...",
    "title":  "Attention Is All You Need",
    "source": "arxiv.org"
  }
}
```

## Capabilities

`arxiv`, `science`, `papers`, `preprints`, `research`

## Usage

```bash
rebar3 shell
```

## License

Apache-2.0
