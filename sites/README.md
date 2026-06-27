# Mesh Demo Sites

Local development copies of the wyse-server hosted mesh demo sites.

## WebTV

```powershell
cd sites\webtv.site
npm run dev
npm run verify
```

## WebRadio

```powershell
cd sites\webradio.site
npm run dev
npm run verify
```

Keep playlist entries relative for mesh hosting:

- `playlist.json`
- `media/file.mp3`
- `media/file.mp4`

The `media/` folders are intentionally ignored so large local debug media can be synced from wyse-server without committing it.

To sync media from an SSH host configured as `wyse`:

```powershell
.\sites\tools\sync-media.ps1 -Site webtv.site
.\sites\tools\sync-media.ps1 -Site webradio.site
```
