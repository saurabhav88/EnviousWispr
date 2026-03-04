import { motion } from 'framer-motion';
import { Scene } from '../components/Scene';
import { Caption } from '../components/Caption';
import styles from './Scene08Reveal.module.css';

export function Scene08Reveal() {
  return (
    <Scene id="scene-08" background="#0f0a1a">
      <div className={styles.sceneInner}>
        <div className={styles.artContainer}>
          <motion.img
            src="/scenes/scene-08-reveal.png"
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
              All of this... <span className={styles.rainbowClean}>was two of us.</span>
            </h2>
          </div>
          <div className={styles.captionWrap}>
            <Caption>
              No investors. No employees.{'\n'}Just a hoodie, a laptop, and Claude Code.
            </Caption>
          </div>
        </div>
      </div>
    </Scene>
  );
}
