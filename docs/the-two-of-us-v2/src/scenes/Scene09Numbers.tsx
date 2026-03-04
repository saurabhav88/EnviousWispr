import { motion, useInView } from 'framer-motion';
import { useRef } from 'react';
import { Scene } from '../components/Scene';
import { Caption } from '../components/Caption';
import { ParticleField } from '../components/ParticleField';
import { RainbowText } from '../components/RainbowText';
import styles from './Scene09Numbers.module.css';

interface StatRowProps {
  number: string;
  label: string;
  rainbow?: boolean;
  delay: number;
}

function StatRow({ number, label, rainbow = false, delay }: StatRowProps) {
  const ref = useRef<HTMLDivElement>(null);
  const isInView = useInView(ref, { once: true, margin: '-5%' });

  return (
    <motion.div
      ref={ref}
      className={styles.statRow}
      initial={{ x: -32 }}
      animate={isInView ? { x: 0 } : {}}
      transition={{ duration: 0.6, delay, ease: 'easeOut' }}
    >
      <span className={styles.statNumber}>
        {rainbow ? <RainbowText>{number}</RainbowText> : number}
      </span>
      <span className={styles.statLabel}>{label}</span>
    </motion.div>
  );
}

function TeamComparison() {
  const ref = useRef<HTMLDivElement>(null);
  const isInView = useInView(ref, { once: true, margin: '-5%' });

  return (
    <motion.div
      ref={ref}
      className={styles.teamComparison}
      initial={{ y: 24 }}
      animate={isInView ? { y: 0 } : {}}
      transition={{ duration: 0.7, delay: 0.2 }}
    >
      <div className={styles.teamOld}>
        <span className={styles.teamNumber}>10</span>
        <span className={styles.teamLabel}>person team</span>
        <div className={styles.strikeBar} />
      </div>
      <motion.div
        className={styles.arrow}
        initial={{ scale: 0.5 }}
        animate={isInView ? { scale: 1 } : {}}
        transition={{ duration: 0.4, delay: 0.6 }}
      >
        →
      </motion.div>
      <motion.div
        className={styles.teamNew}
        initial={{ scale: 0.8 }}
        animate={isInView ? { scale: 1 } : {}}
        transition={{ duration: 0.5, delay: 0.8, ease: 'easeOut' }}
      >
        <span className={styles.teamNumberNew}>
          <RainbowText>2</RainbowText>
        </span>
        <span className={styles.teamLabelNew}>of us</span>
      </motion.div>
    </motion.div>
  );
}

export function Scene09Numbers() {
  return (
    <Scene
      id="scene-09-numbers"
      minHeight="100vh"
      background="#0a0a1a"
     
    >
      <motion.img
        src="/scenes/scene-09-numbers.png"
        alt=""
        className={styles.bgIllustration}
        loading="lazy"
        initial={{ opacity: 0 }}
        whileInView={{ opacity: 0.25 }}
        viewport={{ once: true }}
        transition={{ duration: 1.5 }}
      />
      <ParticleField
        density={70}
        colors={['#7c3aed', '#a855f7', '#4c1d95', '#c4b5fd', '#ffffff']}
        driftSpeed={0.15}
      />

      <div className={styles.wrapper}>
        <motion.div
          className={styles.label}
          initial={{ y: -12 }}
          whileInView={{ y: 0 }}
          viewport={{ once: true }}
          transition={{ duration: 0.6 }}
        >
          PROOF OF CONCEPT → <span className={styles.labelHighlight}>PROOF OF POSSIBLE</span>
        </motion.div>

        <TeamComparison />

        <div className={styles.divider} />

        <div className={styles.statsGrid}>
          <StatRow number="1" label="person building it" delay={0.1} />
          <StatRow number="1" label="AI partner making it real" delay={0.25} />
          <StatRow number="1" label="real product, shipped" rainbow delay={0.4} />
          <StatRow number="∞" label="real users" rainbow delay={0.55} />
        </div>

        <motion.div
          className={styles.captionArea}
          initial={{ y: 20 }}
          whileInView={{ y: 0 }}
          viewport={{ once: true, margin: '-5%' }}
          transition={{ duration: 0.7, delay: 0.3 }}
        >
          <Caption>
            The future of building things isn&apos;t <em>bigger teams</em>. It&apos;s <em>better partners</em>.
          </Caption>
        </motion.div>
      </div>
    </Scene>
  );
}
