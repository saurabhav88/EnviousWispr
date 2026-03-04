import { motion } from 'framer-motion';
import { Scene } from '../components/Scene';
import { Caption } from '../components/Caption';
import styles from './Scene02Canvas.module.css';

export function Scene02Canvas() {
  return (
    <Scene
      id="scene-02-canvas"
      minHeight="100vh"
      background="radial-gradient(ellipse at 50% 30%, rgba(60,40,0,0.35), #0f0a1a)"
      parallaxIntensity={0.12}
    >
      <motion.img
        src="/scenes/scene-02-canvas.png"
        alt=""
        className={styles.bgIllustration}
        loading="lazy"
        initial={{ opacity: 0 }}
        whileInView={{ opacity: 0.6 }}
        viewport={{ once: true }}
        transition={{ duration: 1.5 }}
      />
      <div className={styles.wrapper}>
        <motion.div
          className={styles.captionArea}
          initial={{ y: 20 }}
          whileInView={{ y: 0 }}
          viewport={{ once: true, margin: '-10%' }}
          transition={{ duration: 0.7, delay: 0.5 }}
        >
          <Caption>
            {"It starts with a simple idea.\nWhat if your voice could do the typing?"}
          </Caption>
        </motion.div>
      </div>
    </Scene>
  );
}
