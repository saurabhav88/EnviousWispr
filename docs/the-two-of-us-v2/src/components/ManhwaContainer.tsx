import styles from './ManhwaContainer.module.css';

interface ManhwaContainerProps {
  children: React.ReactNode;
}

export function ManhwaContainer({ children }: ManhwaContainerProps) {
  return <div className={styles.container}>{children}</div>;
}
