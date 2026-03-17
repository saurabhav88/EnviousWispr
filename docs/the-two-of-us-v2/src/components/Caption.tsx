import { motion, useInView } from 'framer-motion';
import { useRef } from 'react';
import styles from './Caption.module.css';

interface CaptionProps {
  children: React.ReactNode;
}

export function Caption({ children }: CaptionProps) {
  const ref = useRef<HTMLParagraphElement>(null);
  const isInView = useInView(ref, { once: true });

  return (
    <motion.p
      ref={ref}
      className={styles.caption}
      initial={{ y: 24 }}
      animate={isInView ? { y: 0 } : {}}
      transition={{ duration: 0.7, delay: 0.3 }}
    >
      {children}
    </motion.p>
  );
}
