export interface SolutionCard {
  href: string;
  eyebrow: string;
  title: string;
  description: string;
  outcome: string;
  accent: 'blue' | 'violet' | 'green' | 'orange' | 'cyan';
}

export const solutions: SolutionCard[] = [
  {
    href: '/solutions/developers/',
    eyebrow: 'For developers',
    title: 'Dictate the work around the code',
    description: 'Turn spoken context into PR descriptions, review comments, issue notes, and technical documentation without sending your audio away.',
    outcome: 'Less typing between thinking and shipping',
    accent: 'blue',
  },
  {
    href: '/solutions/ai-polish/',
    eyebrow: 'AI polish choices',
    title: 'Choose how rough speech becomes clean text',
    description: 'Compare deterministic cleanup, local AI models, and bring-your-own-key cloud polish without blurring their privacy boundaries.',
    outcome: 'The cleanup you want with the boundary you choose',
    accent: 'violet',
  },
  {
    href: '/solutions/offline-dictation/',
    eyebrow: 'Offline dictation',
    title: 'Keep dictating when the internet disappears',
    description: 'Run speech recognition and text cleanup on your Apple Silicon Mac after the required models have been downloaded.',
    outcome: 'Reliable voice input on planes, trains, and quiet networks',
    accent: 'green',
  },
  {
    href: '/solutions/open-source/',
    eyebrow: 'Open source',
    title: 'Inspect the app behind the privacy claims',
    description: 'Read the GPLv3 app source, review the local processing path, build it yourself, or follow active development on GitHub.',
    outcome: 'Trust based on code you can inspect',
    accent: 'orange',
  },
  {
    href: '/solutions/writers/',
    eyebrow: 'For writers',
    title: 'Speak the first draft before the editor wakes up',
    description: 'Turn outlines, rough prose, essays, and scripts into editable text while keeping the original thought and your revision pass separate.',
    outcome: 'More raw material and less time facing a blank page',
    accent: 'cyan',
  },
];
