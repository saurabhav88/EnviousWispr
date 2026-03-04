import { motion, useInView } from 'framer-motion';
import { useRef } from 'react';
import { Scene } from '../components/Scene';
import { Caption } from '../components/Caption';
import styles from './Scene03Conversation.module.css';

export function Scene03Conversation() {
  const ref = useRef<HTMLDivElement>(null);
  const isInView = useInView(ref, { once: true, margin: '-10%' });

  return (
    <Scene id="scene-03" background="linear-gradient(180deg, #0f0a1a 0%, #1a1028 100%)">
      <div className={styles.sceneInner} ref={ref}>
        <div className={styles.artContainer}>
          <motion.img src="/scenes/scene-03-conversation.png" alt="" className={styles.bgIllustration} loading="lazy"
            initial={{ opacity: 0 }} whileInView={{ opacity: 1 }} viewport={{ once: true }} transition={{ duration: 1.5 }} />
          <div className={styles.headerWrap}>
            <h2 className={styles.title}>He found Claude Code...</h2>
          </div>
          <div className={styles.captionWrap}>
            <Caption>
              So they started talking. Not coding.{' '}
              <span className={styles.cyanText}>Talking.</span>
            </Caption>
          </div>
        </div>
      </div>
    </Scene>
  );
}
