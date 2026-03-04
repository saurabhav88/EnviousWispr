import { motion } from 'framer-motion';
import { Scene } from '../components/Scene';
import styles from './Scene07Explainer.module.css';

export function Scene07Explainer() {
  return (
    <Scene id="scene-07-explainer" background="linear-gradient(180deg, #0f0a1a 0%, #1a0a2a 100%)">
      <div className={styles.sceneInner}>
        <div className={styles.artContainer}>
          <motion.img
            src={`${import.meta.env.BASE_URL}scenes/scene-07-explainer.jpg`}
            alt=""
            className={styles.bgIllustration}
            loading="lazy"
            initial={{ opacity: 0 }}
            whileInView={{ opacity: 1 }}
            viewport={{ once: true }}
            transition={{ duration: 1.5 }}
          />
          <div className={styles.captionWrap}>
            <h2 className={styles.title}><span className={styles.rainbowClean}>Available now for macOS</span></h2>
          </div>
        </div>
      </div>
    </Scene>
  );
}
