import { motion, useInView } from 'framer-motion';
import { useRef } from 'react';
import { Scene } from '../components/Scene';
import styles from './Scene06Product.module.css';

export function Scene06Product() {
  const ref = useRef<HTMLDivElement>(null);
  const isInView = useInView(ref, { once: true, margin: '-10%' });

  return (
    <Scene
      id="scene-06-product"
      minHeight="100vh"
      background="radial-gradient(ellipse at 50% 40%, rgba(40,30,0,0.4), #0f0a1a)"
      parallaxIntensity={0.06}
    >
      <motion.img
        src="/scenes/scene-06-product.png"
        alt=""
        className={styles.bgIllustration}
        loading="lazy"
        initial={{ opacity: 0 }}
        whileInView={{ opacity: 0.65 }}
        viewport={{ once: true }}
        transition={{ duration: 1.5 }}
      />
      <div ref={ref} className={styles.container}>
        <motion.p
          className={styles.caption}
          initial={{ opacity: 0, y: 24 }}
          animate={isInView ? { opacity: 1, y: 0 } : {}}
          transition={{ duration: 0.7, delay: 0.6 }}
        >
          Speak. It <span className={styles.emphasized}>listens</span>. It{' '}
          <span className={styles.emphasized}>writes</span>.{'\n'}
          <span className={styles.gold}>Better than you said it.</span>
        </motion.p>
      </div>
    </Scene>
  );
}
