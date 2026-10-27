package com.ghe.golden.server;

import java.io.ByteArrayOutputStream;
import java.io.File;
import java.io.FileOutputStream;
import java.io.OutputStream;
import java.io.StringWriter;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.security.MessageDigest;
import java.util.ArrayList;
import java.util.HashMap;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Vector;
import javax.xml.parsers.DocumentBuilder;
import javax.xml.parsers.DocumentBuilderFactory;
import javax.xml.transform.Transformer;
import javax.xml.transform.TransformerFactory;
import javax.xml.transform.dom.DOMSource;
import javax.xml.transform.stream.StreamResult;
import org.w3c.dom.Document;
import org.w3c.dom.Element;
import org.w3c.dom.NodeList;

/**
 * JDK 8 golden fixtures for server persistence and credentials: device XML, WIO switch model XML,
 * and password hashing, using TEST passwords only.
 * The WIO inputs are the synthetic profiles in Tests/Fixtures/server/input/wioProfiles.
 * Usage: java com.ghe.golden.server.ServerGolden <wioProfiles input dir> <output dir>
 */
public class ServerGolden {
    public static void main(String[] args) throws Exception {
        File data = new File(args[0]);
        File out = new File(args[1]);
        out.mkdirs();
        writeDeviceManager(new File(out, "dm_golden.xml"));
        for (String n : new String[] {"eight_way_select", "test_bank_a", "pulse_trio", "band_filter_seven", "rx_splitter_b", "amp_toggle"}) {
            Model m = load(new File(data, n + ".xml"));
            write(new File(out, "wio_" + n + ".xml"), m.toXML());
        }
        write(new File(out, "wio_virtual.xml"), virtualModel().toXML());
        write(new File(out, "wio_special.xml"), specialModel().toXML());
        writeCredentials(out);
    }

    static void write(File f, String s) throws Exception {
        Files.write(f.toPath(), s.getBytes(StandardCharsets.UTF_8));
    }

    static String serialize(Document document) throws Exception {
        Transformer transformer = TransformerFactory.newInstance().newTransformer();
        StreamResult result = new StreamResult(new StringWriter());
        transformer.setOutputProperty("indent", "yes");
        transformer.transform(new DOMSource(document), result);
        return result.getWriter().toString();
    }

    // MARK: Device XML

    static final class Panel {
        String name = "", port = "N/A", deviceType = "RT-21", wioAddress = "N/A", subType = "N/A";
        boolean ptt = false, initial = false;
        double fixedHeading = -123456.0, cloneOffset = -654321.0;
    }

    static Panel p(String name, String port, String type, String wio, String sub, boolean ptt, boolean initial) {
        Panel x = new Panel();
        x.name = name; x.port = port; x.deviceType = type; x.wioAddress = wio; x.subType = sub; x.ptt = ptt; x.initial = initial;
        return x;
    }

    static void writeDeviceManager(File f) throws Exception {
        Panel[] panels = new Panel[100];
        for (int i = 0; i < 100; i++) panels[i] = new Panel();
        panels[0] = p("Tower", "RT21-NET", "RT-21", "N/A", "N/A", false, true);
        panels[1] = p("40m Fixed", "N/A", "Fixed Antenna", "N/A", "N/A", false, true);
        panels[1].fixedHeading = 999.0;
        panels[2] = p("Tower 15m", "COM5", "Cloned Antenna", "N/A", "RT-21", false, true);
        panels[2].cloneOffset = -30.0;
        panels[3] = p("Yagi1,Yagi2,Yagi3", "COM7", "GHE Base", "4", "Stack Match (1-4)", true, true);
        panels[4] = p("A&B <x> \"q\" 'a' é€\ttab", "/dev/cu.usbserial-A1", "GHE Base", "255", "8 Simple", true, false);
        panels[5] = p("Fixed unset", "N/A", "Fixed Antenna", "N/A", "N/A", false, false);
        panels[6] = p("Clone unset", "COM5", "Cloned Antenna", "N/A", "RT-21", false, false);
        panels[7] = p("Tiny", "N/A", "Fixed Antenna", "N/A", "N/A", false, false);
        panels[7].fixedHeading = 1.0E-4;
        panels[8] = p("Clone 12.5", "COM5", "Cloned Antenna", "3", "RT-21", false, false);
        panels[8].cloneOffset = 12.5;
        panels[9] = p("DCU", "COM9", "DCU-1", "N/A", "N/A", false, false);
        panels[10] = p("Virt", "COM7", "Virtual Switch", "0", "8 Simple", true, false);
        panels[11] = p("line1\nline2\r", "N/A", "RT-21", "N/A", "N/A", false, false);
        panels[12] = p("Emoji 📡 >", "N/A", "RT-21", "N/A", "N/A", false, false);
        panels[13] = p("Big", "N/A", "Fixed Antenna", "N/A", "N/A", false, false);
        panels[13].fixedHeading = 12345678.9;

        Document document = DocumentBuilderFactory.newInstance().newDocumentBuilder().newDocument();
        Element rootElement = document.createElement("DeviceManager");
        document.appendChild(rootElement);
        for (int i = 0; i < panels.length; i++) {
            Panel x = panels[i];
            Element e = document.createElement("panel");
            e.setAttribute("name", x.name);
            e.setAttribute("order", "" + i);
            e.setAttribute("port", x.port);
            e.setAttribute("deviceType", x.deviceType);
            e.setAttribute("wioAddress", x.wioAddress);
            e.setAttribute("subType", x.subType);
            e.setAttribute("basePTT", x.ptt ? "true" : "false");
            if ("Fixed Antenna".equals(x.deviceType)) e.setAttribute("fixedHeading", "" + x.fixedHeading);
            if ("Cloned Antenna".equals(x.deviceType)) e.setAttribute("cloneOffset", "" + x.cloneOffset);
            e.setAttribute("initialState", "" + x.initial);
            rootElement.appendChild(e);
        }
        write(f, serialize(document));
    }

    // MARK: WIO switch model XML

    static final class Model {
        String name;
        int displayType = 1;
        boolean lockout, virtual;
        Vector<String> order = new Vector<>();
        Map<String, int[]> table = new HashMap<>();
        Map<String, Integer> heading = new HashMap<>(), beamwidth = new HashMap<>();
        Map<String, Boolean> bidir = new HashMap<>();
        Map<String, Double> lower = new HashMap<>(), upper = new HashMap<>();
        List<String[]> virtuals = new ArrayList<>();

        String toXML() throws Exception {
            Document document = DocumentBuilderFactory.newInstance().newDocumentBuilder().newDocument();
            Element root = document.createElement("WioDevice");
            String dt = null;
            switch (displayType) {
                case 1: dt = "SWITCH"; break;
                case 2: dt = "HEADING"; break;
                case 3: dt = "BANDSWITCH"; break;
                case 4: dt = "ON_OFF_BANK"; break;
            }
            root.setAttribute("displayType", dt);
            document.appendChild(root);
            Element nameElement = document.createElement("devicename");
            nameElement.appendChild(document.createTextNode(name));
            root.appendChild(nameElement);
            root.setAttribute("matrixlockout", lockout ? "true" : "false");
            root.setAttribute("virtualSwitch", virtual ? "true" : "false");
            Element posElement = document.createElement("positions");
            root.appendChild(posElement);
            for (int i = 0; i < order.size(); i++) {
                String n = order.get(i);
                Element p = document.createElement("position");
                p.setAttribute("order", "" + i);
                p.setAttribute("name", n);
                p.setAttribute("bidirectional", "" + bidir.get(n));
                p.setAttribute("heading", "" + (heading.get(n) == null ? 0 : heading.get(n)));
                p.setAttribute("beamwidth", "" + (beamwidth.get(n) == null ? 0 : beamwidth.get(n)));
                p.setAttribute("lowerFreq", "" + (lower.get(n) == null ? 0.0 : lower.get(n)));
                p.setAttribute("upperFreq", "" + (upper.get(n) == null ? 0.0 : upper.get(n)));
                if (virtual) {
                    for (String[] v : virtuals) {
                        if (v[0].equals(n)) {
                            Element e = document.createElement("real");
                            e.setAttribute("name", v[1]);
                            e.setAttribute("position", v[2]);
                            p.appendChild(e);
                        }
                    }
                } else {
                    int[] s = table.get(n);
                    if (s == null) s = new int[8];
                    for (int j = s.length - 1; j > -1; j--) {
                        Element e = document.createElement("pin");
                        e.setAttribute("number", "" + j);
                        String st;
                        switch (s[j]) {
                            case -1: st = "dont-care"; break;
                            case 1: st = "on"; break;
                            case 2: st = "momentary"; break;
                            default: st = "off";
                        }
                        e.setAttribute("state", st);
                        p.appendChild(e);
                    }
                }
                posElement.appendChild(p);
            }
            return serialize(document);
        }
    }

    static Model load(File f) throws Exception {
        DocumentBuilder builder = DocumentBuilderFactory.newInstance().newDocumentBuilder();
        Document doc = builder.parse(f);
        Element root = doc.getDocumentElement();
        Model m = new Model();
        m.name = doc.getElementsByTagName("devicename").item(0).getTextContent();
        String dt = root.getAttribute("displayType");
        if ("SWITCH".equals(dt)) m.displayType = 1;
        else if ("HEADING".equals(dt)) m.displayType = 2;
        else if ("BANDSWITCH".equals(dt)) m.displayType = 3;
        else if ("ON_OFF_BANK".equals(dt)) m.displayType = 4;
        m.lockout = "true".equals(root.getAttribute("matrixlockout"));
        m.virtual = "true".equals(root.getAttribute("virtualSwitch"));
        NodeList list = doc.getElementsByTagName("position");
        for (int i = 0; i < list.getLength(); i++) {
            Element e = (Element) list.item(i);
            String n = e.getAttribute("name");
            m.heading.put(n, Integer.parseInt(e.getAttribute("heading")));
            m.beamwidth.put(n, Integer.parseInt(e.getAttribute("beamwidth")));
            m.lower.put(n, Double.parseDouble(e.getAttribute("lowerFreq")));
            m.upper.put(n, Double.parseDouble(e.getAttribute("upperFreq")));
            m.bidir.put(n, Boolean.parseBoolean(e.getAttribute("bidirectional")));
            m.order.add(Integer.parseInt(e.getAttribute("order")), n);
            NodeList reals = e.getElementsByTagName("real");
            for (int j = 0; j < reals.getLength(); j++) {
                Element r = (Element) reals.item(j);
                m.virtuals.add(new String[] {n, r.getAttribute("name"), r.getAttribute("position")});
            }
            NodeList pins = e.getElementsByTagName("pin");
            int[] s = new int[pins.getLength()];
            for (int j = 0; j < pins.getLength(); j++) {
                Element pe = (Element) pins.item(j);
                int idx = Integer.parseInt(pe.getAttribute("number"));
                String st = pe.getAttribute("state");
                if ("on".equals(st)) s[idx] = 1;
                else if ("off".equals(st)) s[idx] = 0;
                else if ("dont-care".equals(st)) s[idx] = -1;
                else if ("momentary".equals(st)) s[idx] = 2;
            }
            m.table.put(n, s);
        }
        return m;
    }

    static void addPos(Model m, String n, int h, int bw, boolean bi, double lo, double up, int[] pins) {
        m.order.add(n);
        m.heading.put(n, h); m.beamwidth.put(n, bw); m.bidir.put(n, bi); m.lower.put(n, lo); m.upper.put(n, up);
        if (pins != null) m.table.put(n, pins);
    }

    static Model virtualModel() {
        Model m = new Model();
        m.name = "Virtual & Co";
        m.displayType = 2;
        m.virtual = true;
        addPos(m, "North", 0, 60, true, 0.0, 0.0, null);
        addPos(m, "South \"S\"", 180, 45, false, 0.0, 0.0, null);
        addPos(m, "Empty", 90, 0, false, 0.0, 0.0, null);
        m.virtuals.add(new String[] {"North", "Ant Switch", "FIRST"});
        m.virtuals.add(new String[] {"North", "Tower", "#123.5"});
        m.virtuals.add(new String[] {"South \"S\"", "Ant <Switch>", "TWO"});
        m.virtuals.add(new String[] {"South \"S\"", "Tower", "$cmd"});
        return m;
    }

    static Model specialModel() {
        Model m = new Model();
        m.name = "Band <&> \u00e9 \"q\" 'a' \t \ud83d\udce1 \u0001";
        m.displayType = 3;
        m.lockout = true;
        addPos(m, "160 M", 0, 0, false, 1.8, 2.0, new int[] {1, 0, -1, 2, 0, 0, 0, 0});
        addPos(m, "Tiny", 359, 360, true, 1.0E-4, 1.0E7, new int[] {0, 1, 0, 0, 0, 0, 0, 1});
        addPos(m, "Four pins", 10, 20, false, 3.5, 3.8, new int[] {1, -1, 2, 0});
        return m;
    }

    // MARK: Credentials (test passwords only)

    static byte[] lowBytes(String s) {
        byte[] b = new byte[s.length()];
        for (int i = 0; i < s.length(); i++) b[i] = (byte) s.charAt(i);
        return b;
    }

    static String hex(byte[] b) {
        StringBuilder sb = new StringBuilder();
        for (byte x : b) sb.append(String.format("%02x", x & 0xff));
        return sb.toString();
    }

    static void writeCredentials(File out) throws Exception {
        LinkedHashMap<String, String> users = new LinkedHashMap<>();
        users.put("alice", "secret1");
        users.put("bob", "hunter22");
        users.put("W1AW-op", "pässwörd€");
        HashMap<String, byte[]> map = new HashMap<>();
        StringBuilder expected = new StringBuilder();
        for (Map.Entry<String, String> e : users.entrySet()) {
            MessageDigest md = MessageDigest.getInstance("SHA-256");
            md.update(e.getKey().getBytes(StandardCharsets.US_ASCII));
            md.update(lowBytes(e.getValue()));
            byte[] h = md.digest();
            map.put(e.getKey(), h);
            expected.append("user\t").append(e.getKey()).append('\t').append(hex(h)).append('\n');
        }
        MessageDigest md = MessageDigest.getInstance("SHA-256");
        md.update(lowBytes("testmaster"));
        md.update(lowBytes("testmaster"));
        byte[] master = md.digest();
        expected.append("master\ttestmaster\t").append(hex(master)).append('\n');
        Files.write(new File(out, "test_credentials_expected.txt").toPath(), expected.toString().getBytes(StandardCharsets.UTF_8));
    }
}
