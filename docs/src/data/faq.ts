export const faq: [string, string][] = [
  ['Is it safe?', 'It deletes only what the tool or your build rebuilds, and it never selects Careful items by default. Docker volumes, dumps and language versions need your explicit tick. Large files and Xcode apps go to the Trash, so you can put them back. You see every item and its size before anything is removed.'],
  ['Why not the App Store?', 'The sandbox cannot reach ~/Library/Developer, ~/.asdf or the Docker socket. Without those, TidyDrive could not do its job. So it ships as a signed and notarized app on GitHub releases only.'],
  ['What does it send?', 'Crash reports through Sentry, and nothing else. No file paths are sent. You can switch crash reports off in Settings. Scanning and cleaning happen on your Mac.'],
  ['When does it warn me?', 'Once, when the disk passes 90%. It can only warn again after the disk drops below 85%.'],
  ['What does it cost?', 'Free for noncommercial use under PolyForm Noncommercial 1.0.0. The source is on GitHub.'],
];
