import { motion } from 'framer-motion';
import { Scene } from '../components/Scene';
import { Caption } from '../components/Caption';
import styles from './Scene03Conversation.module.css';

export function Scene03Conversation() {

  return (
    <Scene id="scene-03" background="linear-gradient(180deg, #0f0a1a 0%, #1a1028 100%)">
      <div className={styles.sceneInner}>
        <div className={styles.artContainer}>
          <motion.img src={`${import.meta.env.BASE_URL}scenes/scene-03-conversation.jpg`} alt="" className={styles.bgIllustration} loading="lazy"
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
