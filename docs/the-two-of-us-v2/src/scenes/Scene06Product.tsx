import { motion } from 'framer-motion';
import { Scene } from '../components/Scene';
import { Caption } from '../components/Caption';
import styles from './Scene06Product.module.css';

export function Scene06Product() {
  return (
    <Scene id="scene-06-product" background="radial-gradient(ellipse at 50% 40%, rgba(40,30,0,0.4), #0f0a1a)">
      <div className={styles.sceneInner}>
        <div className={styles.artContainer}>
          <motion.img
            src={`${import.meta.env.BASE_URL}scenes/scene-06-product.jpg`}
            alt=""
            className={styles.bgIllustration}
            loading="lazy"
            initial={{ opacity: 0 }}
            whileInView={{ opacity: 1 }}
            viewport={{ once: true }}
            transition={{ duration: 1.5 }}
          />
          <div className={styles.headerWrap}>
            <h2 className={styles.title}>And Finally...</h2>
          </div>
          <div className={styles.captionWrap}>
            <Caption>
              EnviousWispr is born.{'\n'}Talk naturally. Paste perfectly.
            </Caption>
          </div>
        </div>
      </div>
    </Scene>
  );
}
