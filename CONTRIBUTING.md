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
2. Build and run from Xcode (see the README). Demo mode (`-demo YES`) runs on made-up meetings and never touches
   your own recordings; use it for anything you want to look at.
3. Run the tests: `cd Packages/TranscriptsKit && swift test`.
4. Open a pull request against `main` and describe what changed and how you checked it.

Every pull request is reviewed and merged by the maintainer; nothing lands on `main` without that approval.

## What to keep in mind

- **Nothing leaves the Mac** except the transcript text that goes to the summary service the user picked. No
  analytics, no uploads, no servers of our own.
- **Only what the user confirms defines a voice.** Automatic names and moved lines may refine a voice but never start
  one, and a correction must be able to undo what followed from a mistake. `Speakers/VoiceProfile.swift` and
  `Speakers/VoiceRecheck.swift` explain how.
- **Every text is translated.** The interface is written in German in the code and translated into nine more
  languages in `Transcripts/Localizable.xcstrings`. After changing texts, run `Tools/localization/extract.sh`; then
  `Tools/localization/catalog.py todo <language> <file>` lists what a language lacks, `catalog.py merge` takes
  translations in and `catalog.py check` checks placeholders and plural forms. Texts stored with a meeting (a voice's
  label, the reason for a suggestion) stay German and are shown through `Strings.label` and `Strings.reason`.
- **Colours and fonts come from `UI/Theme.swift`.** Every colour needs a light and a dark value.
- **Show what changed.** A change people will notice gets a line in `CHANGELOG.md` under "Unreleased", and the README
  follows: its feature sections, the shortcut table, "Good to know", and the pictures (`Tools/readme-images.sh`,
  which also makes the website's). When what the app stores or sends changes, so do the privacy policy and the
  support page in `Website/`.
- Match the style of the code around you. Comments explain why, not what.

## Releases

Versions follow semantic versioning. The version lives in `Config/Shared.xcconfig`; each release gets an entry in
`CHANGELOG.md` and a tag of the form `v0.1.0`.
