import { motion } from 'framer-motion';
import { Scene } from '../components/Scene';
import { Caption } from '../components/Caption';
import styles from './Scene05Building.module.css';

export function Scene05Building() {
  return (
    <Scene id="scene-05-building" background="linear-gradient(180deg, #0a1a14 0%, #0f0a1a 100%)">
      <div className={styles.sceneInner}>
        <div className={styles.artContainer}>
          <motion.img
            src="/scenes/scene-05-building.png"
            alt=""
            className={styles.bgIllustration}
            loading="lazy"
            initial={{ opacity: 0 }}
            whileInView={{ opacity: 1 }}
            viewport={{ once: true }}
            transition={{ duration: 1.5 }}
          />
          <div className={styles.captionWrapTop}>
            <Caption>
              He described what he wanted. Claude built it.
            </Caption>
          </div>
          <div className={styles.captionWrapBottom}>
            <Caption>
              All it took was two minds and a weekend.
            </Caption>
          </div>
        </div>
      </div>
    </Scene>
  );
}
