import { motion } from 'framer-motion';
import { Scene } from '../components/Scene';
import { Caption } from '../components/Caption';
import styles from './Scene10Horizon.module.css';

export function Scene10Horizon() {
  return (
    <Scene id="scene-10-horizon" background="linear-gradient(180deg, #0a0a1a 0%, #0d0820 50%, #0a0012 100%)">
      <div className={styles.sceneInner}>
        <div className={styles.artContainer}>
          <motion.img
            src="/scenes/scene-10-horizon.png"
            alt=""
            className={styles.bgIllustration}
            loading="lazy"
            initial={{ opacity: 0 }}
            whileInView={{ opacity: 1 }}
            viewport={{ once: true }}
            transition={{ duration: 1.5 }}
          />
          <div className={styles.headerWrap}>
            <h2 className={styles.title}>
              Everyone has an idea.{'\n'}
              <strong>Now everyone can build it.</strong>
            </h2>
          </div>
          <div className={styles.captionWrap}>
            <div className={styles.wordmark}>
              <span className={styles.rainbowClean}>EnviousWispr</span>
            </div>
            <Caption>Made by a team of two.</Caption>
          </div>
        </div>
      </div>
    </Scene>
  );
}
