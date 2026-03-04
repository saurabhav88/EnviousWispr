import { motion } from 'framer-motion';
import { Scene } from '../components/Scene';
import { Caption } from '../components/Caption';
import styles from './Scene02Canvas.module.css';

export function Scene02Canvas() {
  return (
    <Scene id="scene-02-canvas" background="radial-gradient(ellipse at 50% 30%, rgba(60,40,0,0.35), #0f0a1a)">
      <div className={styles.sceneInner}>
        <div className={styles.artContainer}>
          <motion.img
            src="/scenes/scene-02-canvas.png"
            alt=""
            className={styles.bgIllustration}
            loading="lazy"
            initial={{ opacity: 0 }}
            whileInView={{ opacity: 1 }}
            viewport={{ once: true }}
            transition={{ duration: 1.5 }}
          />
          <div className={styles.headerWrap}>
            <Caption>
              It starts with a simple idea.{'\n'}What if your voice could do the typing?
            </Caption>
          </div>
        </div>
      </div>
    </Scene>
  );
}
