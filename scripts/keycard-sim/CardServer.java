// Real Keycard applet (status-keycard, compiled from source) inside jCardSim. One APDU per
// stdin line (hex) -> one response per stdout line (hex). Lets the JS keycard-sdk drive the
// exact applet code a card runs, with only the NFC transport replaced.
import com.licel.jcardsim.smartcardio.CardSimulator;
import com.licel.jcardsim.utils.AIDUtil;
import javacard.framework.AID;
import javax.smartcardio.*;
import java.io.*;
import im.status.keycard.KeycardApplet;
import im.status.keycard.IdentApplet;

public class CardServer {
  static byte[] hex(String s) { byte[] b = new byte[s.length() / 2]; for (int i = 0; i < b.length; i++) b[i] = (byte) Integer.parseInt(s.substring(2 * i, 2 * i + 2), 16); return b; }
  static String hex(byte[] b) { StringBuilder sb = new StringBuilder(); for (byte x : b) sb.append(String.format("%02x", x)); return sb.toString(); }
  public static void main(String[] a) throws Exception {
    CardSimulator sim = new CardSimulator();
    byte[] inst = hex("a00000080400010101");
    ByteArrayOutputStream bos = new ByteArrayOutputStream(); bos.write(inst.length); bos.write(inst);
    AID aid = AIDUtil.create(hex("a000000804000101"));
    sim.installApplet(aid, KeycardApplet.class, bos.toByteArray(), (short) 0, (byte) bos.size());
    // Ident applet (holds the card's identity certificate, as on a real card), as Status' tests install it.
    byte[] identInst = hex("a00000080400010401");
    bos.reset(); bos.write(identInst.length); bos.write(identInst); bos.write(new byte[] {0x01, 0x00, 0x02, (byte) 0xC9, 0x00});
    sim.installApplet(AIDUtil.create(hex("a000000804000104")), IdentApplet.class, bos.toByteArray(), (short) 0, (byte) bos.size());
    BufferedReader in = new BufferedReader(new InputStreamReader(System.in));
    PrintStream out = new PrintStream(new FileOutputStream(FileDescriptor.out), true);
    System.err.println("CARD READY");
    String line;
    while ((line = in.readLine()) != null) {
      line = line.trim(); if (line.isEmpty()) continue;
      ResponseAPDU r = sim.transmitCommand(new CommandAPDU(hex(line)));
      out.println(hex(r.getBytes()));
    }
  }
}
