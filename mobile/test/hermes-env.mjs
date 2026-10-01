// Preload: make Node look like the phone's JS engine (Hermes) before anything else loads -
// no Node Buffer (the app installs the `buffer` polyfill, mobile/index.ts), no TextDecoder.
import { Buffer as Poly } from "buffer";
delete globalThis.TextDecoder;
globalThis.Buffer = Poly;
