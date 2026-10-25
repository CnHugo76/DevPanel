import { useEffect, useRef, type ReactNode } from 'react';
import type { IconKind, StatusLabel } from '../lib/status';

export function StatusIcon({ kind, pulse = true }: { kind: IconKind; pulse?: boolean }) {
  const anim = pulse && (kind === 'starting' || kind === 'stopping') ? ' pulse' : '';
  return <span className={`st ${kind}${anim}`} aria-hidden="true" />;
}

export function StatusBadge({ label, extra }: { label: StatusLabel; extra?: ReactNode }) {
  return (
    <span className={`badge tone-${label.tone}`}>
      <StatusIcon kind={label.icon} />
      {label.text}
      {extra}
    </span>
  );
}

export function Spinner() {
  return <span className="spin" aria-label="进行中" />;
}

export function Modal({
  title,
  children,
  footer,
  onClose,
  wide,
}: {
  title: ReactNode;
  children: ReactNode;
  footer: ReactNode;
  onClose: () => void;
  wide?: boolean;
}) {
  const ref = useRef<HTMLDivElement>(null);
  useEffect(() => {
    const prev = document.activeElement as HTMLElement | null;
    const first = ref.current?.querySelector<HTMLElement>('[data-autofocus]') ?? ref.current?.querySelector<HTMLElement>('button');
    first?.focus();
    const onKey = (e: KeyboardEvent) => {
      if (e.key === 'Escape') {
        e.stopPropagation();
        onClose();
      }
    };
    window.addEventListener('keydown', onKey, true);
    return () => {
      window.removeEventListener('keydown', onKey, true);
      prev?.focus?.();
    };
  }, [onClose]);
  return (
    <div className="modal-scrim" onMouseDown={(e) => e.target === e.currentTarget && onClose()}>
      <div className={`modal${wide ? ' wide' : ''}`} role="dialog" aria-modal="true" ref={ref}>
        <h3>{title}</h3>
        <div className="mbody">{children}</div>
        <div className="mfoot">{footer}</div>
      </div>
    </div>
  );
}

/** Close a popover/menu on outside click or Escape. */
export function useDismiss(open: boolean, ref: React.RefObject<HTMLElement | null>, close: () => void): void {
  useEffect(() => {
    if (!open) return;
    const onDown = (e: MouseEvent) => {
      if (ref.current && !ref.current.contains(e.target as Node)) close();
    };
    const onKey = (e: KeyboardEvent) => {
      if (e.key === 'Escape') close();
    };
    document.addEventListener('mousedown', onDown);
    document.addEventListener('keydown', onKey);
    return () => {
      document.removeEventListener('mousedown', onDown);
      document.removeEventListener('keydown', onKey);
    };
  }, [open, ref, close]);
}
