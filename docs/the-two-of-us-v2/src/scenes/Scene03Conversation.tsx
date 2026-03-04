import { motion, useInView } from 'framer-motion';
import { useRef } from 'react';
import { Scene } from '../components/Scene';
import { Caption } from '../components/Caption';
import styles from './Scene03Conversation.module.css';

const containerVariants = {
  hidden: {},
  visible: {
    transition: {
      staggerChildren: 0.35,
      delayChildren: 0.2,
    },
  },
};

const bubbleVariants = {
  hidden: { scale: 0.85, y: 16 },
  visible: {
    scale: 1,
    y: 0,
    transition: { duration: 0.5, ease: 'easeOut' },
  },
};

export function Scene03Conversation() {
  const ref = useRef<HTMLDivElement>(null);
  const isInView = useInView(ref, { once: true, margin: '-10%' });

  return (
    <Scene id="scene-03" minHeight="100vh" background="linear-gradient(180deg, #0f0a1a 0%, #1a1028 100%)">
      <motion.img src="/scenes/scene-03-conversation.png" alt="" className={styles.bgIllustration} loading="lazy"
        initial={{ opacity: 0 }} whileInView={{ opacity: 0.55 }} viewport={{ once: true }} transition={{ duration: 1.5 }} />
      <div className={styles.wrapper} ref={ref}>
        <motion.div className={styles.bubbles} variants={containerVariants} initial="hidden" animate={isInView ? 'visible' : 'hidden'}>
          <motion.div className={`${styles.bubble} ${styles.bubbleHuman}`} variants={bubbleVariants}>
            "Hey... can you help me build something?"
          </motion.div>
          <motion.div className={`${styles.bubble} ${styles.bubbleClaude}`} variants={bubbleVariants}>
            "Of course. Tell me about the idea first."
          </motion.div>
          <motion.div className={`${styles.bubble} ${styles.bubbleHuman}`} variants={bubbleVariants}>
            "Not an app. More like... a whole idea."
          </motion.div>
          <motion.div className={`${styles.bubble} ${styles.bubbleClaude}`} variants={bubbleVariants}>
            "Let's build it together."
          </motion.div>
        </motion.div>

        <Caption>
          So they started talking. Not coding.{' '}
          <span className={styles.cyanText}>Talking.</span>
        </Caption>
      </div>
    </Scene>
  );
}
