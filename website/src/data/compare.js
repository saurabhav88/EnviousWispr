// Dated primary-source facts for the compare hub. Sources are rendered beside
// the table so qualifications and provenance travel with the comparison.
export const updated = '2026-09-12';
export const checked = new Intl.DateTimeFormat('en-GB', {
  day: 'numeric', month: 'long', year: 'numeric', timeZone: 'UTC',
}).format(new Date(updated + 'T00:00:00Z'));

export const products = [
  { id: 'ew', name: 'EnviousWispr', note: 'Free, private dictation', mark: '/favicon.svg', own: true, url: '/features/', sources: [['Features', '/features/'], ['Privacy', '/why-offline/'], ['Languages', '/help/multi-language-dictation/'], ['Requirements', '/help/system-requirements/']] },
  { id: 'flow', name: 'Wispr Flow', note: 'Cloud dictation', mark: '/home/marks/wisprflow.png', url: '/compare/wisprflow/', sources: [['Plans', 'https://wisprflow.ai/pricing'], ['How it works', 'https://docs.wisprflow.ai/articles/2772472373-what-is-flow']] },
  { id: 'super', name: 'Superwhisper', note: 'Model and mode choice', mark: '/home/marks/superwhisper.png', url: '/compare/superwhisper/', sources: [['Plans & features', 'https://superwhisper.com/'], ['Offline use', 'https://superwhisper.com/offline-transcription']] },
  { id: 'fluid', name: 'FluidVoice', note: 'Free, configurable dictation', mark: '/home/marks/fluidvoice.png', url: '/compare/fluidvoice/', sources: [['Features & requirements', 'https://github.com/altic-dev/FluidVoice'], ['App license', 'https://github.com/altic-dev/FluidVoice/blob/main/LICENSE']] },
  { id: 'spokenly', name: 'Spokenly', note: 'Local and cloud flexibility', mark: '/home/marks/spokenly.avif', url: '/compare/spokenly/', sources: [['Plans', 'https://spokenly.app/pricing'], ['Offline use', 'https://spokenly.app/docs/local-only-mode'], ['Modes', 'https://spokenly.app/docs/modes'], ['Mac support', 'https://spokenly.app/dictation-for-mac'], ['Source code', 'https://spokenly.app/open-source']] },
];

// The detailed MacWhisper page keeps its own pair when the hub shortlist changes.
export const macWhisperProducts = [products.find(product => product.id === 'ew'),
  { id: 'mac', name: 'MacWhisper', note: 'Files, meetings & dictation', url: '/compare/macwhisper/', sources: [['Plans & features', 'https://www.macwhisper.com/'], ['Documentation', 'https://macwhisper.helpscoutdocs.com/']] },
];

const cell = (title, note = '') => ({ title, note });
export const groups = [
  { title: 'Cost & setup', rows: [
    { label: 'Price', cells: {
      ew: cell('Free', 'Dictation, file transcription and local AI polish.'),
      flow: cell('Free + Pro', '2,000 words/week on desktop. Pro $15/month, or $12/month billed annually.'),
      super: cell('Free + Pro', 'Unlimited Whisper models free. Pro $8.49/month; annual and lifetime options.'),
      mac: cell('Free + Pro', 'Pro €64, one-time purchase on the official site.'),
      fluid: cell('Free', 'Local dictation and Fluid Intelligence. Cloud provider fees may apply.'),
      spokenly: cell('Free + Pro', 'Local models free. Pro $99.99/year ($8.33/month), billed annually.'),
    } },
    { label: 'Getting started', cells: {
      ew: cell('No account', 'Install the app and download your models.'),
      flow: cell('Sign in', 'An account and internet connection.'),
      super: cell('Choose a model', 'No account needed for offline transcription.'),
      mac: cell('Download the app', 'Activate a license for Pro features.'),
      fluid: cell('Choose your setup', 'Grant permissions, set a shortcut and choose your models.'),
      spokenly: cell('No account for local use', 'Install local models. Pro activation depends on purchase source.'),
    } },
  ] },
  { title: 'Privacy & processing', rows: [
    { label: 'Where audio goes', cells: {
      ew: cell('Stays on your Mac', 'Transcription always runs on-device.'),
      flow: cell('Cloud', 'Audio is sent for cloud transcription.'),
      super: cell('Local or cloud', 'Depends on the voice model you choose.'),
      mac: cell('Local available', 'Choose local models to keep audio on your Mac.'),
      fluid: cell('Local-first', 'Voice and text stay local unless you opt into a cloud AI provider.'),
      spokenly: cell('Local or cloud', 'Local models keep audio on-device. Cloud models send it to a provider.'),
    } },
    { label: 'Works offline', cells: {
      ew: cell('Yes', 'After setup, with local transcription and polish models.'),
      flow: cell('Internet required', 'Cloud-connected dictation.'),
      super: cell('With local models', 'Download the models first.'),
      mac: cell('With local models', 'Cloud services need an internet connection.'),
      fluid: cell('With local models', 'Download speech and Fluid Intelligence models first.'),
      spokenly: cell('With local models', 'Local Only Mode blocks external network access.'),
    } },
    { label: 'AI text cleanup', cells: {
      ew: cell('Local AI included', 'Cloud polish also available with your own provider.¹'),
      flow: cell('Automatic, in cloud', 'Cleanup is part of the dictation workflow.'),
      super: cell('Local or cloud AI', 'Pro includes local and cloud language models.'),
      mac: cell('Local or cloud AI', 'Pro supports AI prompts and grammar improvement.'),
      fluid: cell('Local AI included', 'Fluid Intelligence, or a cloud provider you choose.'),
      spokenly: cell('Local or cloud AI', 'Apple Intelligence on supported Macs; cloud via your key or Pro.'),
    } },
  ] },
  { title: 'Everyday use', rows: [
    { label: 'Workflow', cells: {
      ew: cell('Dictate & transcribe files', 'Dictation into your apps, plus recordings you import.'),
      flow: cell('Dictation across devices', 'Mac, Windows, iOS and Android.'),
      super: cell('Configurable dictation', 'Voice models, custom prompts and modes.'),
      mac: cell('Files, meetings & dictation', 'Includes subtitle and batch workflows.'),
      fluid: cell('Dictation & voice actions', 'Configurable speech models, Write Mode and Command Mode.'),
      spokenly: cell('Dictation across devices', 'Mac, Windows, Linux and iOS. Per-mode prompts and models.'),
    } },
    { label: 'Languages', cells: {
      ew: cell('99+ with WhisperKit', 'Parakeet covers 25 European languages.'),
      flow: cell('100+', 'Language support varies by feature.'),
      super: cell('100+', 'Model-dependent language support.'),
      mac: cell('100+', 'Model-dependent language support.'),
      fluid: cell('99 with Whisper', 'Model-dependent; Parakeet v3 covers 25 languages.'),
      spokenly: cell('100+', 'Model-dependent language support.'),
    } },
    { label: 'On Apple Silicon', cells: {
      ew: cell('M1 or later', 'macOS 14+. Intel Macs are not supported.'),
      flow: cell('Supported', 'Speech processing runs in the cloud.'),
      super: cell('Supported', 'Recommended for offline models.'),
      mac: cell('Supported', 'Local transcription uses your Mac.'),
      fluid: cell('Supported', 'macOS 15+. Intel support through Whisper models.'),
      spokenly: cell('Supported', 'macOS 13.3+. Local model support varies on Intel.'),
    } },
    { label: 'App source code', cells: {
      ew: cell('Open source', 'GPLv3. AI models have their own licenses.'),
      flow: cell('Proprietary'),
      super: cell('Proprietary'),
      mac: cell('Proprietary'),
      fluid: cell('Open-source app', 'GPLv3. Fluid Intelligence is a separate, private runtime.'),
      spokenly: cell('Proprietary'),
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
