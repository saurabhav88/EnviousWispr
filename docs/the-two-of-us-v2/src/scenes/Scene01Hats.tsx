import { motion } from 'framer-motion';
import { Scene } from '../components/Scene';
import styles from './Scene01Hats.module.css';

export function Scene01Hats() {

  return (
    <Scene id="scene-01-hats" background="radial-gradient(ellipse at 50% 70%, rgba(60,20,80,0.6), #0f0a1a)">
      <div className={styles.sceneInner}>
        <div className={styles.artContainer}>
          <motion.img
            src={`${import.meta.env.BASE_URL}scenes/scene-01-hats.jpg`}
            alt=""
            className={styles.bgIllustration}
            loading="lazy"
            initial={{ opacity: 0 }}
            whileInView={{ opacity: 1 }}
            viewport={{ once: true }}
            transition={{ duration: 1.5 }}
          />
          <div className={styles.headerWrap}>
            <h2 className={styles.title}>Turns out...</h2>
          </div>
        </div>
      </div>
    </Scene>
  );
}
