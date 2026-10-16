# Webhooks

A webhook destination posts each transcript you send to it as JSON. It works with any service that gives you a URL to call: the catch hooks in Zapier, Make and n8n, or a small server of your own.

## Request

- Method: `POST`
- Content-Type: `application/json`
- Timeout: 30 seconds without an answer, and 2 minutes for the whole request
- Headers: whatever you add in Send To settings. Header values are kept in the Keychain, not in Parola's settings.
- Redirects: Parola follows a redirect only to the same scheme, host and port. Any other redirect counts as a failed delivery.

An address has to start with `https://`. Plain `http://` is accepted for this Mac and the local network and shows a "Not encrypted" note: `localhost`, `127.0.0.0/8`, `10.0.0.0/8`, `172.16.0.0/12`, `192.168.0.0/16`, `169.254.0.0/16`, the IPv6 ranges `::1`, `fc00::/7` and `fe80::/10`, names ending in `.local`, `.lan` or `.home.arpa`, and single-word names such as `nas`. Numeric forms like `134744072` or `0x08080808` count as the address they stand for. `http://` to a public host is refused when you save.

The address is stored in Parola's settings, so it appears in a Settings export. A catch-hook address (Zapier, Make, n8n) or one with `user:password@` works like a password: anyone who has it can post to the hook.

A 2xx answer counts as delivered. These answers will not change on a second try, so Parola stops and reports them: 400, 401, 403, 404, 410, 422, and any redirect it does not follow. A timeout, a 408, a 429, a 5xx or a network error is retried the way every destination is retried.

## Body

`parola` is the schema version. Within a version, fields are added and never changed or removed.

```json
{
  "parola": 1,
  "id": "6F2B1C0E-...",
  "title": "Weekly sync",
  "aiTitle": "Planning the Q3 launch",
  "createdAt": "2026-10-16T09:30:00Z",
  "duration": 1834.5,
  "language": "en",
  "category": "meeting",
  "sourceApp": "us.zoom.xos",
  "text": "Welcome back to the show. Glad to be here ...",
  "summary": "Ada and Grace go over the export rewrite.",
  "chapters": [{ "title": "Welcome", "start": 0 }],
  "actionItems": ["Write the release note"],
  "segments": [
    { "start": 0, "end": 3.5, "speaker": "Ada", "text": "Welcome back to the show." }
  ]
}
```

| Field | Type | Notes |
| --- | --- | --- |
| `parola` | number | Schema version, `1`. |
| `id` | string | The library entry's id. |
| `title` | string | The entry's title. |
| `aiTitle` | string | Left out when the on-device title pass never ran. |
| `createdAt` | string | ISO 8601, UTC. |
| `duration` | number | Seconds. Left out when unknown. |
| `language` | string | Language code of the transcript. |
| `category` | string | `transcription`, `meeting` or `dictation`. |
| `sourceApp` | string | Bundle ID of the app the audio came from. Left out when unknown. |
| `text` | string | The transcript as one string, segments joined by a space. |
| `summary` | string | Left out when there is no summary. |
| `chapters` | array | `title` and `start` (seconds). Empty when there are none. |
| `actionItems` | array of strings | Empty when there are none. |
| `segments` | array | `start`, `end`, `speaker` (left out when unlabelled) and `text`. Present only when "Include segments" is on. |

"Send Test" posts a sample transcript with this same shape and shows the HTTP status the server answered.
