import styles from './Scene.module.css';

interface SceneProps {
  id: string;
  minHeight?: string;
  background?: string;
  children: React.ReactNode;
}

export function Scene({ id, minHeight = '100vh', background, children }: SceneProps) {
  return (
    <section
      id={id}
      className={styles.scene}
      style={{ minHeight, background }}
    >
      <div className={styles.content}>
        {children}
      </div>
    </section>
  );
}
