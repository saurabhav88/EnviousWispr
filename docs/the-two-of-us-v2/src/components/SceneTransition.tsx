import styles from './SceneTransition.module.css';

interface SceneTransitionProps {
  from?: string;
  to?: string;
}

export function SceneTransition({ from = 'var(--bg-dark)', to = 'var(--bg-dark)' }: SceneTransitionProps) {
  return (
    <div
      className={styles.transition}
      style={{ background: `linear-gradient(to bottom, ${from}, ${to})` }}
    />
  );
}
