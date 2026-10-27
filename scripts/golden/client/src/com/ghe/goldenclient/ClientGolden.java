package com.ghe.goldenclient;

import java.awt.Color;
import java.io.File;
import java.io.FileOutputStream;
import java.io.FileWriter;
import java.io.PrintWriter;
import java.util.Properties;
import javax.xml.parsers.DocumentBuilderFactory;
import javax.xml.transform.Transformer;
import javax.xml.transform.TransformerFactory;
import javax.xml.transform.dom.DOMSource;
import javax.xml.transform.stream.StreamResult;
import org.w3c.dom.Document;
import org.w3c.dom.Element;

/** Golden fixtures: client .properties/.xml files exactly as Java 8 writes them. */
public class ClientGolden {
   static final String RS = "\u001e";
   static final String US = "\u001f";
   static final String TOWER = "Tower 40m" + RS + ":17220";
   static final String YAGI = "Yagi Top" + RS + ":17220";
   static final String SWITCH = "Band SW" + RS + ":17220";

   public static void main(String[] args) throws Exception {
      File out = new File(args[0]);
      out.mkdirs();

      // --- Properties goldens (Mac line separator) ---
      Properties dev = new Properties();
      dev.setProperty(TOWER, "160M 80M 40M 20M 15M 10M 50 ");
      dev.setProperty(YAGI, "");
      dev.setProperty("Odd key=:#! x", "value with \\ backslash and  spaces ");
      dev.setProperty(SWITCH + US + "20m", "Red");
      store(dev, new File(out, "props_device.properties"), "File stores rotor names and bands for tray display:");

      // Integer.toString(argb, 16) for Color.getRGB(), and parse back via new Color(Integer.parseInt(s,16)).
      try (PrintWriter pw = new PrintWriter(new File(out, "colors.txt"), "UTF-8")) {
         int[] rgbs = {0x00FF00, 0x00FEFF, 0xFF0000, 0x000000, 0xFFFFFF, 0x123456, 0x7F7F7F};
         for (int rgb : rgbs) {
            Color c = new Color(rgb);
            String s = Integer.toString(c.getRGB(), 16);
            Color back = new Color(Integer.parseInt(s, 16));
            pw.println(String.format("%06x", rgb) + " " + s + " " + String.format("%06x", back.getRGB() & 0xFFFFFF));
         }
      }

      // --- XML goldens ---
      writeXml(presetFrames(true), new File(out, "presetFrames.xml"));
      writeXml(presetFrames(false), new File(out, "presetFrames_empty.xml"));
      writeXml(phidgets(), new File(out, "phidgets.xml"));
   }

   @SuppressWarnings({"rawtypes", "unchecked"})
   static Document presetFrames(boolean full) throws Exception {
      Document d = DocumentBuilderFactory.newInstance().newDocumentBuilder().newDocument();
      Element root = d.createElement("presetFrames");
      d.appendChild(root);
      if (full) {
         root.appendChild(frame(d, "Tower 40m preset selection", true, true, 10, 20, 400, 400));
         root.appendChild(frame(d, "A&B <\"x\"> preset selection", false, false, -5, 0, 300, 250));
         root.appendChild(frame(d, "Global preset selection", false, false, 0, 0, 400, 400));
      }
      return d;
   }

   static Element frame(Document d, String name, boolean visible, boolean keep, int x, int y, int w, int h) {
      Element e = d.createElement("presetFrame");
      e.setAttribute("name", name);
      e.setAttribute("visible", "" + visible);
      e.setAttribute("keepVisible", "" + keep);
      e.setAttribute("x", "" + x);
      e.setAttribute("y", "" + y);
      e.setAttribute("width", "" + w);
      e.setAttribute("height", "" + h);
      return e;
   }

   static Document phidgets() throws Exception {
      Document d = DocumentBuilderFactory.newInstance().newDocumentBuilder().newDocument();
      Element root = d.createElement("phidgets");
      d.appendChild(root);
      Element p1 = d.createElement("phidget");
      p1.setAttribute("name", "Tower 40m:17220");
      p1.setAttribute("sn", "123456");
      root.appendChild(p1);
      Element p2 = d.createElement("phidget");
      p2.setAttribute("name", "Global preset selection");
      p2.setAttribute("sn", "98765");
      root.appendChild(p2);
      return d;
   }

   static void writeXml(Document d, File f) throws Exception {
      Transformer t = TransformerFactory.newInstance().newTransformer();
      t.setOutputProperty("indent", "yes");
      try (FileWriter w = new FileWriter(f)) {
         t.transform(new DOMSource(d), new StreamResult(w));
      }
   }

   static void store(Properties p, File f, String comment) throws Exception {
      try (FileOutputStream fos = new FileOutputStream(f)) {
         p.store(fos, comment);
      }
   }

}
