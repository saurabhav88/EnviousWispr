import React from 'react';
import { motion, useInView } from 'framer-motion';
import { useRef } from 'react';
import { Scene } from '../components/Scene';
import styles from './Scene05Building.module.css';

const steps = ['Capture', 'Transcribe', 'Polish', 'Ship'];
const stepColors = ['#00ffff', '#00fa9a', '#c084fc', '#adff2f'];

export function Scene05Building() {
  const ref = useRef<HTMLDivElement>(null);
  const isInView = useInView(ref, { once: true, margin: '-10%' });

  return (
    <Scene
      id="scene-05-building"
      minHeight="100vh"
      background="linear-gradient(180deg, #0a1a14 0%, #0f0a1a 100%)"
      parallaxIntensity={0.08}
    >
      <motion.img
        src="/scenes/scene-05-building.png"
        alt=""
        className={styles.bgIllustration}
        loading="lazy"
        initial={{ opacity: 0 }}
        whileInView={{ opacity: 0.6 }}
        viewport={{ once: true }}
        transition={{ duration: 1.5 }}
      />
      <div ref={ref} className={styles.container}>
        <div className={styles.flow}>
          {steps.map((step, i) => (
            <React.Fragment key={step}>
              <motion.span
                className={styles.stepLabel}
                style={{ color: stepColors[i], textShadow: `0 0 20px ${stepColors[i]}40` }}
                initial={{ opacity: 0, y: 16 }}
                animate={isInView ? { opacity: 1, y: 0 } : {}}
                transition={{ duration: 0.5, delay: 0.2 + i * 0.15 }}
              >
                {step}
              </motion.span>
              {i < steps.length - 1 && (
                <motion.span
                  className={styles.arrow}
                  initial={{ opacity: 0 }}
                  animate={isInView ? { opacity: 0.4 } : {}}
                  transition={{ duration: 0.3, delay: 0.35 + i * 0.15 }}
                >
                  →
                </motion.span>
              )}
            </React.Fragment>
          ))}
        </div>

        <motion.p
          className={styles.caption}
          initial={{ opacity: 0, y: 24 }}
          animate={isInView ? { opacity: 1, y: 0 } : {}}
          transition={{ duration: 0.7, delay: 0.9 }}
        >
          Ideas became <span className={styles.emphasized}>real</span>. Not in months. In{' '}
          <span className={styles.emphasized}>conversations</span>.
        </motion.p>
      </div>
    </Scene>
  );
}
