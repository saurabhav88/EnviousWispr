import { motion, useScroll, useTransform, useInView } from 'framer-motion';
import { useRef } from 'react';
import styles from './Scene.module.css';

interface SceneProps {
  id: string;
  minHeight?: string;
  background?: string;
  parallaxIntensity?: number;
  children: React.ReactNode;
}

export function Scene({ id, minHeight = '100vh', background, parallaxIntensity = 0.1, children }: SceneProps) {
  const ref = useRef<HTMLDivElement>(null);
  const isInView = useInView(ref, { once: true, margin: '-10%' });
  const { scrollYProgress } = useScroll({ target: ref, offset: ['start end', 'end start'] });
  const y = useTransform(scrollYProgress, [0, 1], [50, -50 * parallaxIntensity]);

  return (
    <motion.section
      ref={ref}
      id={id}
      className={styles.scene}
      style={{ minHeight, background }}
      initial={{ y: 40 }}
      animate={isInView ? { y: 0 } : {}}
      transition={{ duration: 0.8, ease: 'easeOut' }}
    >
      <motion.div style={{ y }} className={styles.content}>
        {children}
      </motion.div>
    </motion.section>
  );
}
