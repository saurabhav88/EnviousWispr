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
];
