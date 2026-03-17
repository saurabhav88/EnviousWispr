import { motion, useInView } from 'framer-motion';
import { useRef } from 'react';
import { Scene } from '../components/Scene';
import { Caption } from '../components/Caption';
import { RainbowText } from '../components/RainbowText';
import styles from './Scene04Office.module.css';

const titleVariants = {
  hidden: { y: -30 },
  visible: {
    y: 0,
    transition: { duration: 0.7, ease: 'easeOut' },
  },
};

export function Scene04Office() {
  const ref = useRef<HTMLDivElement>(null);
  const isInView = useInView(ref, { once: true, margin: '-10%' });

  return (
    <Scene id="scene-04" background="radial-gradient(ellipse at 50% 50%, rgba(60,20,80,0.4), #0f0a1a)">
      <div className={styles.sceneInner} ref={ref}>
        <div className={styles.artContainer}>
          <motion.img src={`${import.meta.env.BASE_URL}scenes/scene-04-office.jpg`} alt="" className={styles.bgIllustration} loading="lazy"
            initial={{ opacity: 0 }} whileInView={{ opacity: 1 }} viewport={{ once: true }} transition={{ duration: 1.5 }} />
          <div className={styles.overlay}>
            <motion.h2 className={styles.title} variants={titleVariants} initial="hidden" animate={isInView ? 'visible' : 'hidden'}>
              <RainbowText>Claude Gets to Work!</RainbowText>
            </motion.h2>
          </div>
          <div className={styles.captionWrap}>
            <Caption>
              Architects, builders, testers — all summoned in seconds.{'\n'}He handled the vision. Claude handled everything else.
            </Caption>
          </div>
        </div>
      </div>
    </Scene>
  );
}
