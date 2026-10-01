// Entropy first: @noble (identity keys, ECIES nonces, receipt ids) draws from
// crypto.getRandomValues, which Hermes does not have. Must load before anything else.
import "react-native-get-random-values";
import { registerRootComponent } from "expo";
import App from "./App";
registerRootComponent(App);
