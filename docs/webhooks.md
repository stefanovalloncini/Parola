# Webhooks

A webhook destination posts each transcript you send to it as JSON. It works with any service that gives you a URL to call: the catch hooks in Zapier, Make and n8n, or a small server of your own.

## Request

- Method: `POST`
- Content-Type: `application/json`
- Timeout: 30 seconds
- Headers: whatever you add in Send To settings. Header values are kept in the Keychain, not in Parola's settings.

An address has to start with `https://`. Plain `http://` is accepted for this Mac and the local network (`localhost`, `127.0.0.1`, `192.168.x.x`, `10.x.x.x`, `172.16-31.x.x`, `.local` names) and shows a "Not encrypted" note. `http://` to a public host is refused when you save.

Any 2xx answer counts as delivered. Any other status, or a network error, is a failed delivery and Parola retries it the way it retries every destination.

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
