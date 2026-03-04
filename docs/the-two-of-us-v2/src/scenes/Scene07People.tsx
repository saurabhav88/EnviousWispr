import { motion } from 'framer-motion';
import { Scene } from '../components/Scene';
import { Caption } from '../components/Caption';
import styles from './Scene07People.module.css';

export function Scene07People() {
  return (
    <Scene id="scene-07" background="linear-gradient(180deg, #1a0a1a 0%, #0f0a1a 100%)">
      <div className={styles.sceneInner}>
        <div className={styles.artContainer}>
          <motion.img
            src="/scenes/scene-07-people.png"
            alt=""
            className={styles.bgIllustration}
            loading="lazy"
            initial={{ opacity: 0 }}
            whileInView={{ opacity: 1 }}
            viewport={{ once: true }}
            transition={{ duration: 1.5 }}
          />
          <div className={styles.headerWrap}>
            <h2 className={styles.title}>Designed for...</h2>
          </div>
          <div className={styles.captionWrap}>
            <Caption>Every word counts.{'\n'}Every moment matters.{'\n'}Yours too.</Caption>
          </div>
        </div>
      </div>
    </Scene>
  );
}
