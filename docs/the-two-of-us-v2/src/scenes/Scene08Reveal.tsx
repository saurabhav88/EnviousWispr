import { motion, useInView } from 'framer-motion';
import { useRef } from 'react';
import { Scene } from '../components/Scene';
import { RainbowText } from '../components/RainbowText';
import styles from './Scene08Reveal.module.css';

export function Scene08Reveal() {
  const ref = useRef<HTMLDivElement>(null);
  const isInView = useInView(ref, { once: true, margin: '-8%' });

  return (
    <Scene id="scene-08" minHeight="120vh" background="#0f0a1a">
      <motion.img src="/scenes/scene-08-reveal.png" alt="" className={styles.bgIllustration} loading="lazy"
        initial={{ opacity: 0 }} whileInView={{ opacity: 0.28 }} viewport={{ once: true }} transition={{ duration: 1.5 }} />
      <div className={styles.wrapper} ref={ref}>
        <motion.span className={styles.eyebrow}
          initial={{ letterSpacing: '0.3em' }}
          animate={isInView ? { letterSpacing: '0.18em' } : {}}
          transition={{ duration: 1, ease: 'easeOut', delay: 0.1 }}>
          The Reveal
        </motion.span>

        <motion.h2 className={styles.mainText}
          initial={{ y: 32 }}
          animate={isInView ? { y: 0 } : {}}
          transition={{ duration: 0.9, ease: [0.22, 1, 0.36, 1], delay: 0.4 }}>
          All of this...{' '}<RainbowText>was two of us.</RainbowText>
        </motion.h2>

        <motion.p className={styles.subText}
          initial={{ y: 20 }}
          animate={isInView ? { y: 0 } : {}}
          transition={{ duration: 0.8, ease: 'easeOut', delay: 0.8 }}>
          One developer. One AI. One apartment, one laptop, one cold cup of coffee at 2 AM.
        </motion.p>

        <motion.div className={styles.signature}
          initial={{}} animate={{}}
          transition={{ duration: 1.2, ease: 'easeOut', delay: 1.2 }}>
          <div className={styles.signatureLine} />
          <span className={styles.signatureText}>EnviousWispr — made with intent</span>
          <div className={styles.signatureLine} />
        </motion.div>
      </div>
    </Scene>
  );
}
