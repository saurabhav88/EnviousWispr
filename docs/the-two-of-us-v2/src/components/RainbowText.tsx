import styles from './RainbowText.module.css';

export function RainbowText({ children }: { children: React.ReactNode }) {
  return <span className={styles.rainbow}>{children}</span>;
}
