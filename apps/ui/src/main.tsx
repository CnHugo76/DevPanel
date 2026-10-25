import { StrictMode } from 'react';
import { createRoot } from 'react-dom/client';
import { App } from './App';
import { setAuthToken } from './api/client';
import './styles.css';

// An embedding shell (phase 2) may provide a token; the browser build relies on the session cookie.
const injected = (globalThis as { __DEVPANEL_TOKEN__?: unknown }).__DEVPANEL_TOKEN__;
if (typeof injected === 'string' && injected) setAuthToken(injected);

createRoot(document.getElementById('root')!).render(
  <StrictMode>
    <App />
  </StrictMode>,
);
