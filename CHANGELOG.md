# Changelog

All notable changes to this project are recorded here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and the project uses
[semantic versioning](https://semver.org).

## [Unreleased]

## [0.1.0] - 2026-10-07

The first version: everything below is new.

### Recording

- **The call and you, separately.** Your microphone and everything the Mac plays (Zoom, Teams, Meet in the browser,
  …) are recorded as two tracks with a Core Audio process tap, without a virtual audio driver, so the app knows for
  certain which lines are yours. The tap is read at the output device's real sample rate and follows it when it
  changes.
- **Speakers instead of headphones work.** After a meeting the call's echo is taken out of your microphone track,
  predicted from the call track itself (delay, room and level per frequency band). Playback has every voice once,
  and your own lines stay complete.
- **A menu bar item and a small floating recorder** you can move anywhere; the live window when you want to read
  along. Pause, markers with a note, and a warning when the microphone or the call stays silent.
- **Knows your calendar.** Meetings are named after the event and know who was invited. A notification with a
  *Record* button when a meeting starts; calls without an event are noticed too, and you're reminded to stop when
  the call ends.
- **Import** of audio and video files: voice memos, Zoom recordings, a meeting recorded in a room.

### Transcripts

- **Transcribed on the Mac.** NVIDIA's Parakeet model runs on the Neural Engine through FluidAudio: a live
  transcript while you talk, and a second, careful pass when the meeting ends. 25 European languages, also mixed.
- **An archive you can search.** Meetings grouped by day, full-text search across every transcript (⌘K), playback
  from any line, and Markdown export.

### Voices and names

- **Learns who is speaking.** Every line of a transcript gets its own voice fingerprint, and a person is all the
  lines assigned to them, grouped by how they sound: their voice (or voices, with another microphone), and strays
  that don't count. A clear match is named automatically, a weaker one is suggested, and an unsure one reads
  "Hai or Julian?", also in the summary.
- **Corrections carry through.** Only what you confirm defines a voice. After every confirmation or correction, every
  voice you haven't settled is judged again, so an early mistake doesn't steer later meetings. Lines that sound
  clearly like someone else move there, marked, with *Keep* and *Move Back*.
- **"Who is this?"** after a meeting: one voice after another, the sample playing, its likely names first; a number
  key or Return names it.
- **Names from the conversation.** Introductions ("I'm Paula"), thanks ("thanks, Jonas"), answers and handovers by
  name, and the calendar's invitees become suggestions, in all ten interface languages, including names that change
  when someone is called by them (Polish "Anno" for Anna).
- **The voice map** at the top of the People screen: every line as a dot, lines that sound alike close together, so
  you see which voices the app could mix up, whose voice falls into two groups and which lines fit nobody.

### Summaries

- Overview, decisions, tasks with owner and due day, and open questions, from Anthropic, OpenAI, Google or a local
  model in Ollama, automatically after each meeting or on request, plus an optional live summary while recording.
  Written in the meeting's language or one you choose. API keys stay in the Keychain.

### Everything else

- **Ten interface languages:** English, German, French, Spanish, Italian, Portuguese, Dutch, Polish, Russian and
  Ukrainian: the languages the speech recognition transcribes best. The app follows macOS, or the language picked in
  Settings.
- Four app icons in Apple's style: automatic (light, dark, tinted or clear with the system), light, dark and indigo.
- A demo mode with made-up meetings (`-demo YES`), in German or English.

[Unreleased]: https://github.com/lukaskaibel/transcripts-app/compare/v0.1.0...HEAD
[0.1.0]: https://github.com/lukaskaibel/transcripts-app/releases/tag/v0.1.0
