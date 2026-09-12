// Dated primary-source facts for the compare hub. Sources are rendered beside
// the table so qualifications and provenance travel with the comparison.
export const checked = '12 September 2026';

export const products = [
  { id: 'ew', name: 'EnviousWispr', note: 'Free, private dictation', mark: '/favicon.svg', own: true, url: '/features/', sources: [['Features', '/features/'], ['Privacy', '/why-offline/'], ['Languages', '/help/multi-language-dictation/'], ['Requirements', '/help/system-requirements/']] },
  { id: 'flow', name: 'Wispr Flow', note: 'Cloud dictation', mark: '/home/marks/wisprflow.png', url: '/compare/wisprflow/', sources: [['Plans', 'https://wisprflow.ai/pricing'], ['How it works', 'https://docs.wisprflow.ai/articles/2772472373-what-is-flow']] },
  { id: 'super', name: 'Superwhisper', note: 'Model and mode choice', mark: '/home/marks/superwhisper.png', url: '/compare/superwhisper/', sources: [['Plans & features', 'https://superwhisper.com/'], ['Offline use', 'https://superwhisper.com/offline-transcription']] },
  { id: 'mac', name: 'MacWhisper', note: 'Files, meetings & dictation', url: '/compare/macwhisper/', sources: [['Plans & features', 'https://www.macwhisper.com/'], ['Documentation', 'https://macwhisper.helpscoutdocs.com/']] },
  { id: 'apple', name: 'Apple Dictation', note: 'Built into your Mac', mark: '/home/marks/apple-dictation.ico', url: '/compare/apple-dictation/', sources: [['Dictation', 'https://support.apple.com/en-gb/guide/mac-help/mh40584/mac'], ['Writing Tools', 'https://support.apple.com/en-ie/guide/mac-help/mchldcd6c260/mac']] },
];

const cell = (title, note = '') => ({ title, note });
export const groups = [
  { title: 'Cost & setup', rows: [
    { label: 'Price', cells: {
      ew: cell('Free', 'Dictation, file transcription and local AI polish.'),
      flow: cell('Free + Pro', '2,000 words/week on desktop. Pro $15/month, or $12/month billed annually.'),
      super: cell('Free + Pro', 'Unlimited Whisper models free. Pro $8.49/month; annual and lifetime options.'),
      mac: cell('Free + Pro', 'Pro €64, one-time purchase on the official site.'),
      apple: cell('Included', 'Part of macOS.'),
    } },
    { label: 'Getting started', cells: {
      ew: cell('No account', 'Install the app and download your models.'),
      flow: cell('Sign in', 'An account and internet connection.'),
      super: cell('Choose a model', 'No account needed for offline transcription.'),
      mac: cell('Download the app', 'Activate a license for Pro features.'),
      apple: cell('Enable in settings', 'System Settings → Keyboard → Dictation.'),
    } },
  ] },
  { title: 'Privacy & processing', rows: [
    { label: 'Where audio goes', cells: {
      ew: cell('Stays on your Mac', 'Transcription always runs on-device.'),
      flow: cell('Cloud', 'Audio is sent for cloud transcription.'),
      super: cell('Local or cloud', 'Depends on the voice model you choose.'),
      mac: cell('Local available', 'Choose local models to keep audio on your Mac.'),
      apple: cell('Device or server', 'Check the Dictation notice in Keyboard settings.'),
    } },
    { label: 'Works offline', cells: {
      ew: cell('Yes', 'After setup, with local transcription and polish models.'),
      flow: cell('Internet required', 'Cloud-connected dictation.'),
      super: cell('With local models', 'Download the models first.'),
      mac: cell('With local models', 'Cloud services need an internet connection.'),
      apple: cell('Depends on setup', 'Keyboard settings show whether internet is required.'),
    } },
    { label: 'AI text cleanup', cells: {
      ew: cell('Local AI included', 'Cloud polish also available with your own provider.¹'),
      flow: cell('Automatic, in cloud', 'Cleanup is part of the dictation workflow.'),
      super: cell('Local or cloud AI', 'Pro includes local and cloud language models.'),
      mac: cell('Local or cloud AI', 'Pro supports AI prompts and grammar improvement.'),
      apple: cell('Separate Writing Tools', 'Requires a supported Apple Intelligence setup.'),
    } },
  ] },
  { title: 'Everyday use', rows: [
    { label: 'Workflow', cells: {
      ew: cell('Dictate & transcribe files', 'Dictation into your apps, plus recordings you import.'),
      flow: cell('Dictation across devices', 'Mac, Windows, iOS and Android.'),
      super: cell('Configurable dictation', 'Voice models, custom prompts and modes.'),
      mac: cell('Files, meetings & dictation', 'Includes subtitle and batch workflows.'),
      apple: cell('Built-in voice typing', 'Enter text wherever you can type on your Mac.'),
    } },
    { label: 'Languages', cells: {
      ew: cell('99+ with WhisperKit', 'Parakeet covers 25 European languages.'),
      flow: cell('100+', 'Language support varies by feature.'),
      super: cell('100+', 'Model-dependent language support.'),
      mac: cell('100+', 'Model-dependent language support.'),
      apple: cell('Varies by language', 'Availability depends on language, region and feature.'),
    } },
    { label: 'On Apple Silicon', cells: {
      ew: cell('M1 or later', 'macOS 14+. Intel Macs are not supported.'),
      flow: cell('Supported', 'Speech processing runs in the cloud.'),
      super: cell('Supported', 'Recommended for offline models.'),
      mac: cell('Supported', 'Local transcription uses your Mac.'),
      apple: cell('Built in', 'Available through macOS settings.'),
    } },
    { label: 'App source code', cells: {
      ew: cell('Open source', 'GPLv3. AI models have their own licenses.'),
      flow: cell('Proprietary'),
      super: cell('Proprietary'),
      mac: cell('Proprietary'),
      apple: cell('Proprietary'),
    } },
  ] },
];

// Keep the complete directory independent from the shorter at-a-glance set.
export const directory = [
  ['Apple Dictation', 'apple-dictation'], ['Dragon', 'dragon'], ['FluidVoice', 'fluidvoice'],
  ['Google Docs Voice Typing', 'google-docs-voice-typing'], ['Handy', 'handy'], ['Juno', 'juno'],
  ['MacWhisper', 'macwhisper'], ['Notta', 'notta'], ['Otter.ai', 'otter-ai'], ['Spokenly', 'spokenly'],
  ['Superwhisper', 'superwhisper'], ['TypeWhisper', 'typewhisper'], ['VoiceInk', 'voiceink'],
  ['Vox', 'vox'], ['whisper.cpp', 'whisper-cpp'], ['Willow Voice', 'willow-voice'], ['Wispr Flow', 'wisprflow'],
];
