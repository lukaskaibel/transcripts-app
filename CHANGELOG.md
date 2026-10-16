# Changelog

All notable changes to this project are recorded here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and the project uses
[semantic versioning](https://semver.org).

## [Unreleased]

### Added

- **iPhone and iPad.** The same app for the meetings around a table: put the phone in the middle, tap *Record* and lock
  the screen. It records the room through the built-in microphone, with a live transcript, tells the voices apart
  afterwards and names the ones it knows, all on the device. On the iPhone, *Record* sits above the tab bar on every
  screen and turns into the running recording's time, level, pause and stop; the recording screen has the transcript
  and the buttons to mark, pause and stop. Inbox, Meetings with today's day plan, Action Items, People with the voice
  map, and Search; a planned meeting offers to record it. The iPad has a sidebar like the Mac, the list with the
  meeting beside it, the inspector when there is room and the live summary beside the live transcript, and the Mac's
  keyboard shortcuts. *Who is this?*, the summary, the speakers and the settings are the Mac's own views laid out for
  a narrow screen. A phone call interrupts a recording, which carries on afterwards, and on iOS 26
  a meeting goes on being processed with the screen locked.
- **iCloud sync.** Settings › General › iCloud keeps meetings, people and the voices the app learned the same on your
  Mac, iPhone and iPad: record on the phone, read on the Mac, and a voice named on one device is known on the others.
  The recordings come along too (*Include recordings*, on by default; about 20 to 60 MB of iCloud storage per hour). It
  uses the private database of your iCloud account through CloudKit, works offline and catches up later, sends a
  meeting once it is finished, and when two devices changed the same thing the later change wins. Someone met on two
  devices before the sync becomes one person. Off until you turn it on; the iPhone offers it when it starts the first
  time. *Delete from iCloud* removes everything there and leaves the devices' data alone. Needs a build signed with a
  team that has iCloud (`TR_ICLOUD = YES` in `Config/Local.xcconfig`).
- **The recording on the Lock Screen and in the Dynamic Island.** On iPhone and iPad a running recording shows as a
  Live Activity: its title, a clock that keeps running, the markers, and buttons to pause, mark a moment and stop,
  without opening the app. *Record a Meeting* starts a recording from Control Center, the Lock Screen, the Action
  Button, Siri or Shortcuts.
- **A sidebar for your day.** Below *Inbox*, *All Meetings*, *Action Items* and *People*, the sidebar shows today: the
  calendar's meetings and your recordings in one list from the morning on, with their times, and meetings you didn't
  record greyed out. Tomorrow folds away below, then the latest meetings; one click opens a recording. *Inbox* gathers
  what waits after a meeting: new summaries and voices without a name. *Action Items* lists the open tasks of every
  meeting, all or only yours. ⌘1–⌘4 go to Inbox, All Meetings, Action Items and People. A meeting opened from the
  inbox, the action items or People goes back there.
- **Only your meetings.** Calendar events with guests that you're neither among nor organizing (a team's shared
  calendar, a colleague's) no longer show up in the sidebar or remind you. *Not my meeting* in an event's popover,
  its context menu or the reminder hides a series or everything from its calendar; Settings › General lists what's
  hidden and brings it back. A meeting that is in two calendars shows once.
- **A website** at [lukaskaibel.github.io/transcripts-app](https://lukaskaibel.github.io/transcripts-app/): the app
  on one screen, with a note that it is coming to the Mac App Store, and the pages a store listing needs: privacy
  policy, terms of use, support with common questions, and the Impressum.

### Changed

- **A Mac app like Apple's own.** The main window is built like Notebook and the Mac's own apps: the system's sidebar,
  glass buttons in the toolbar with search, and the inspector on the right (⌃⌘I). A meeting reads like a note:
  a large title, the summary with headings and its action items as a checklist, and *Summary* and *Transcript* in the
  toolbar to switch between them. The inspector lists the meeting's details and its people as Contacts would, with how
  long each one spoke, instead of bars and percentages. Buttons are capsules, the command palette floats like
  Spotlight, playback is a bar floating over the page, and the menu bar's menu looks like the system's menus.
- **Nobody is named while you record.** The floating recorder is a small glass capsule with the time, the sound coming
  in, pause and stop; with the pointer over it, it shows the last words it heard, and it says when no sound comes from
  the call. The live window has a large timer, the sound of the last seconds, the transcript in paragraphs (only your
  own lines are marked) and pause, stop and a marker floating at the bottom. Who is talking is settled after the
  meeting, from the whole recording, where it is right far more often. On the iPhone the recording screen has the time,
  the sound and the buttons at the bottom, as in Voice Memos.
- **Naming a voice is one question.** A quiet bar above the summary says how many voices have no name.
  *Name Voices…* asks about them one at a time, the way Photos asks about a face: the voice plays and the app says
  whom it thinks it is, *Is this Jonas Weber?*, answered with *Yes* (Return) or *Someone Else* (the other guesses,
  the invitees, everyone known, a new name, you, or nobody in particular). The suggestion cards, the name chips in the
  transcript and the numbered list are gone. A click on a speaker's name in the transcript names the voice, or with
  *Only This Passage* gives just those lines to someone else; lines the app moved and a speaker who sounds like two
  voices wait behind the ⓘ next to the person in the inspector.

- **Summaries go into detail.** Below the overview, decisions, action items and open questions, the summary now goes
  through every topic of the meeting with what was reported, the arguments, who does what and where it landed. Each part has a button that copies it (on the Mac when the pointer is over it), the action items copy as a
  checklist with owner and due day, a single task from its row, and the whole summary as Markdown with ⇧⌘C or from a
  meeting's menu. A task you checked off stays checked off when the summary is written again. Summaries written
  before have no topics until you write them again.

- The app asks for the microphone in words that fit the Mac, the iPhone and the iPad alike.

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
