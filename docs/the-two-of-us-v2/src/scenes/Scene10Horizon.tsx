import { motion } from 'framer-motion';
import { Scene } from '../components/Scene';
import { ParticleField } from '../components/ParticleField';
import { RainbowText } from '../components/RainbowText';
import styles from './Scene10Horizon.module.css';

export function Scene10Horizon() {
  return (
    <Scene
      id="scene-10-horizon"
      minHeight="100vh"
      background="linear-gradient(180deg, #0a0a1a 0%, #0d0820 50%, #0a0012 100%)"
     
    >
      <motion.img
        src="/scenes/scene-10-horizon.png"
        alt=""
        className={styles.bgIllustration}
        loading="lazy"
        initial={{ opacity: 0 }}
        whileInView={{ opacity: 0.65 }}
        viewport={{ once: true }}
        transition={{ duration: 1.5 }}
      />
      <ParticleField
        density={80}
        colors={['#7c3aed', '#a855f7', '#4c1d95', '#f8f5ff', '#e6c200']}
        driftSpeed={0.1}
      />

      <div className={styles.wrapper}>
        <motion.div
          className={styles.captionTop}
          initial={{ y: -20 }}
          whileInView={{ y: 0 }}
          viewport={{ once: true }}
          transition={{ duration: 0.8, delay: 0.2 }}
        >
          <span className={styles.captionLine1}>Everyone has an idea.</span>
          <motion.span
            className={styles.captionLine2}
            initial={{}}
            whileInView={{}}
            viewport={{ once: true }}
            transition={{ duration: 0.8, delay: 0.6 }}
          >
            Now everyone can build it.
          </motion.span>
        </motion.div>

        <motion.div
          className={styles.wordmark}
          initial={{ y: 24 }}
          whileInView={{ y: 0 }}
          viewport={{ once: true }}
          transition={{ duration: 0.9, delay: 0.4 }}
        >
          <div className={styles.wordmarkText}>
            <RainbowText>EnviousWispr</RainbowText>
          </div>
          <p className={styles.madeBy}>Made by a team of two.</p>
        </motion.div>
      </div>
    </Scene>
  );
}
