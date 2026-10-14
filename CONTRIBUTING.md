# Contributing

Thanks for wanting to help. This is a small project with one maintainer, so a little coordination up front saves
everyone time.

## Before you start

- **Bugs:** open an issue with what you did, what you expected and what happened, and your audio setup (call app,
  headphones or speakers). Screenshots help for anything visual. Please don't attach recordings of other people.
- **Features and larger changes:** open an issue first and describe the idea. The app is deliberately small and keeps
  everything on the Mac; not every feature fits, and it is better to find that out before you write the code.
- **Small fixes** (typos, obvious bugs, a better translation): a pull request without an issue is fine.

## Making a change

1. Fork the repository and create a branch from `main`.
2. Build and run from Xcode (see the README), on the Mac and, if your change shows there, on an iPhone and an iPad
   simulator. Demo mode (`-demo YES`) runs on made-up meetings and never touches your own recordings; use it for
   anything you want to look at.
3. Run the tests: `cd Packages/TranscriptsKit && swift test`, and `Tools/test-ios.sh` for the iPhone and iPad app.
4. Open a pull request against `main` and describe what changed and how you checked it.

Every pull request is reviewed and merged by the maintainer; nothing lands on `main` without that approval.

## What to keep in mind

- **Nothing leaves the device** except the transcript text that goes to the summary service the user picked and, when
  the user turns on iCloud sync, their own data to their own private iCloud. No analytics, no servers of our own.
- **What belongs to a meeting, a person or a voice syncs.** A new table or column for them needs a trigger in
  `Sync/SyncSchema.swift` (so a change is noticed) and a place in the payloads of `Sync/SyncStore.swift` (so it travels);
  `SyncTests` checks that a meeting arrives whole on another device.
- **One view for every platform.** A view the Mac, the iPhone and the iPad all show lives once, in `UI/` by topic,
  and adapts where it must (`Platform.isMobile`, `#if os(macOS)`), so a change shows everywhere. Only window chrome is
  per platform: `UI/Mac/` (sidebar, menu bar, floating recorder, command palette) and `UI/iOS/` (tabs, the iPad's
  sidebar, the screens around the shared views). Colours, fonts and button sizes come from `UI/Theme.swift`, which
  sizes them for a pointer on the Mac and for a finger on iPhone and iPad.
- **Only what the user confirms defines a voice.** Automatic names and moved lines may refine a voice but never start
  one, and a correction must be able to undo what followed from a mistake. `Speakers/VoiceProfile.swift` and
  `Speakers/VoiceRecheck.swift` explain how.
- **Every text is translated.** The interface is written in German in the code and translated into nine more
  languages in `Transcripts/Localizable.xcstrings` (the widget extension's texts in
  `TranscriptsWidgets/Localizable.xcstrings`). After changing texts, run `Tools/localization/extract.sh` (it compiles
  for the Mac and for iOS, since some texts exist on one of them only); then
  `Tools/localization/catalog.py todo <language> <file>` (with `--widgets` for the extension) lists what a language lacks, `catalog.py merge` takes
  translations in and `catalog.py check` checks placeholders and plural forms. Texts stored with a meeting (a voice's
  label, the reason for a suggestion) stay German and are shown through `Strings.label` and `Strings.reason`.
- **Colours and fonts come from `UI/Theme.swift`.** Every colour needs a light and a dark value.
- **Show what changed.** A change people will notice gets a line in `CHANGELOG.md` under "Unreleased", and the README
  follows: its feature sections, the shortcut table, "Good to know", and the pictures (`Tools/readme-images.sh`,
  which also makes the website's). When what the app stores or sends changes, so do the privacy policy and the
  support page in `Website/`.
- Match the style of the code around you. Comments explain why, not what.

## Releases

Versions follow semantic versioning. The version lives in `Config/Base.xcconfig` (the app and its widget extension
share it); each release gets an entry in `CHANGELOG.md` and a tag of the form `v0.1.0`.

iCloud sync stores four record types (`Meeting`, `MeetingAudio`, `Person`, `Voiceprint`) in the container
`iCloud.<bundle id>`. Debug builds create them in CloudKit's development environment as they save; before a release
that changes them, deploy the schema to production in the CloudKit Console (icloud.developer.apple.com), or builds from
the App Store and TestFlight can't save them.
