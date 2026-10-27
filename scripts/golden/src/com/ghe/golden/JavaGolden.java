package com.ghe.golden;

import java.io.*;
import java.net.URLDecoder;
import java.net.URLEncoder;
import java.nio.charset.StandardCharsets;
import java.util.*;

/**
 * Generates golden fixtures for the GHEKit Java-compat codecs. Must run on a Java 8 JRE.
 * Usage: java com.ghe.golden.JavaGolden <outDir>
 */
public final class JavaGolden {
   private static File out;

   public static void main(String[] args) throws Exception {
      if (!System.getProperty("java.version").startsWith("1.8")) {
         throw new IllegalStateException("Run on Java 8, got " + System.getProperty("java.version"));
      }
      out = new File(args[0]);
      out.mkdirs();
      doubles();
      parseDoubles();
      cp1252();
      properties();
      dates();
      urlCoding();
      System.out.println("Fixtures written to " + out.getAbsolutePath());
   }

   // MARK: helpers

   private static PrintWriter writer(String name) throws IOException {
      return new PrintWriter(new OutputStreamWriter(new FileOutputStream(new File(out, name)), StandardCharsets.UTF_8));
   }

   private static String hex(byte[] b) {
      StringBuilder sb = new StringBuilder();
      for (byte x : b) sb.append(String.format("%02x", x & 0xff));
      return sb.toString();
   }

   private static String hexUtf8(String s) {
      return hex(s.getBytes(StandardCharsets.UTF_8));
   }

   private static void writeBytes(String name, byte[] data) throws IOException {
      try (FileOutputStream fos = new FileOutputStream(new File(out, name))) {
         fos.write(data);
      }
   }

   // MARK: Double.toString

   private static void doubles() throws IOException {
      LinkedHashSet<Double> values = new LinkedHashSet<>();
      double[] edge = {0.001, 0.00099, 1e7, 9999999.999, 9999999.0, 1e-3, 1e-4, Double.NaN,
            Double.POSITIVE_INFINITY, Double.NEGATIVE_INFINITY, -0.0, 0.0, 359.99999999999994, 360.0,
            358.4, 271.0, 45.3, 0.1, 0.2, 0.3, 1.0 / 3, 2.0 / 3, 100.0, 1e21, 1e22, 1e23, 2e23,
            2.82879384806159E17, 1.0E-5, 2.0E-3, 5e-324, Double.MIN_VALUE, Double.MIN_NORMAL,
            Double.MAX_VALUE, -Double.MAX_VALUE, 4.35, 0.5, 123456789.0, 12345678.9, 1234567.89,
            9007199254740992.0, 9007199254740993.0, 1.7976931348623157E308, 4.9E-324, 2.2250738585072014E-308,
            Math.PI, Math.E, 7.0, 7.3, 14.0, 14.35, 50.0, 144.0, 1.8, 3.5, 28.0};
      for (double d : edge) {
         values.add(d);
         values.add(-d);
         values.add(Math.nextUp(d));
         values.add(Math.nextDown(d));
      }
      for (int i = 0; i <= 3600; i++) {
         values.add(i * 0.1);
         values.add(i / 10.0);
      }
      for (int e = -325; e <= 309; e++) {
         double p = Double.parseDouble("1e" + e);
         values.add(p);
         values.add(Math.nextUp(p));
         values.add(Math.nextDown(p));
      }
      for (int e = -1074; e <= 1023; e += 3) {
         values.add(Math.scalb(1.0, e));
      }
      Random r = new Random(20260722L);
      for (int i = 0; i < 2500; i++) values.add(r.nextDouble() * 360.0);
      for (int i = 0; i < 2500; i++) values.add(Double.longBitsToDouble(r.nextLong()));
      for (int i = 0; i < 2500; i++) values.add(Math.pow(10, r.nextDouble() * 40 - 20) * (r.nextBoolean() ? 1 : -1));
      for (int i = 0; i < 1000; i++) values.add((double) (r.nextInt(3600001)) / 1000.0);
      for (int i = 0; i < 500; i++) values.add((double) r.nextLong());
      try (PrintWriter w = writer("double_tostring.txt")) {
         for (double d : values) {
            w.print(String.format("%016x", Double.doubleToRawLongBits(d)));
            w.print('\t');
            w.print(Double.toString(d));
            w.print('\n');
         }
      }
   }

   private static void parseDoubles() throws IOException {
      String[] inputs = {"123", "123.", ".5", "1e2", "123d", "123f", "123D", "123F", "NaN", "Infinity", "-Infinity",
            "+Infinity", "+NaN", "-NaN", "+1", " 12 ", "\t5\n", "\u0000 7 \u001f", "0x1p3", "0x1.8p1", "0X.8P1",
            "0x1P-2d", "0x1p", "0x1", "1e", ".", "", " ", "abc", "1,5", "1.5.5", "nan", "infinity", "1_000",
            "1e400", "-1e400", "4.9e-325", "2.4703282292062328E-324", "2.4703282292062327E-324", "1D", "1.0e+2",
            "1.0E-2", "-0", "-0.0", "Infinityx", "NaNd", "e5", "+", "-", "1e+", "1e-", "--1", "+-1", "0.1f",
            "358.4", "271,5", "1.7976931348623157E308", "1.7976931348623159E308", "00012.5000",
            "123456789012345678901234567890", "0.000000000000000000000000000001", "1.\u0660", "\u0661",
            "１", "12 34", "12\u00a0", "1e2.5", "0x", "0xg", "1ee2", "1.e3", ".e3", "-.5", "+.5e-1"};
      try (PrintWriter w = writer("double_parse.txt")) {
         for (String s : inputs) {
            String result;
            try {
               result = String.format("%016x", Double.doubleToRawLongBits(Double.parseDouble(s)));
            } catch (NumberFormatException e) {
               result = "ERR";
            }
            w.print(hexUtf8(s) + "\t" + result + "\n");
         }
      }
   }

   // MARK: Cp1252

   private static void cp1252() throws IOException {
      try (PrintWriter w = writer("cp1252_decode.txt")) {
         for (int b = 0; b < 256; b++) {
            String s = new String(new byte[]{(byte) b}, "Cp1252");
            w.print(String.format("%02x\t%04x\n", b, (int) s.charAt(0)));
         }
      }
      List<Integer> cps = new ArrayList<>();
      for (int c = 0; c <= 0x02FF; c++) cps.add(c);
      for (int c = 0x2000; c <= 0x2200; c++) cps.add(c);
      cps.addAll(Arrays.asList(0x4E2D, 0x0410, 0x03A9, 0xFFFD, 0xFEFF, 0x1F600, 0x1D11E, 0xFB01));
      try (PrintWriter w = writer("cp1252_encode.txt")) {
         for (int cp : cps) {
            if (cp >= 0xD800 && cp <= 0xDFFF) continue;
            byte[] b = new String(Character.toChars(cp)).getBytes("Cp1252");
            w.print(String.format("%04x\t%s\n", cp, hex(b)));
         }
      }
   }

   // MARK: Properties

   private static final String[][] PROPS = {
         {"port", "17220"},
         {"Tower 40m\u001e:17220", "true"},
         {"Band SW\u001e192.168.1.5:17220", "160 80 40 20"},
         {"6-Pack\u001e:17220\u001fNorth", "Cyan"},
         {"key with spaces", "  leading and trailing  "},
         {"a=b:c#d!e", "x=y:z#w!v"},
         {"#starts", "!bang"},
         {"back\\slash", "C:\\Users\\ghe"},
         {"tab\tnl\ncr\rff\f", "tab\tnl\ncr\rff\f"},
         {"caf\u00e9", "\u00e9t\u00e9 \u20ac \u4e2d"},
         {"del\u007f", "nbsp\u00a0\u00ff"},
         {"", "empty key"},
         {"empty value", ""},
         {" ", " "},
         {"emoji", "\ud83d\ude00"},
         {"rotorcolors", "-ff0100"},
         {"ctrl\u0001\u001d", "\u0000\u001f"},
   };

   private static void properties() throws IOException {
      // One store per entry so the line is independent of Hashtable order.
      try (PrintWriter w = writer("props_entries.txt")) {
         for (String[] kv : PROPS) {
            Properties p = new Properties();
            p.setProperty(kv[0], kv[1]);
            ByteArrayOutputStream bos = new ByteArrayOutputStream();
            p.store(bos, null);
            String text = new String(bos.toByteArray(), StandardCharsets.ISO_8859_1);
            String line = text.substring(text.indexOf('\n') + 1); // drop the "#date" line
            w.print(hexUtf8(kv[0]) + "\t" + hexUtf8(kv[1]) + "\t" + hex(line.getBytes(StandardCharsets.ISO_8859_1)) + "\n");
         }
      }
      String[] comments = {"Settings for server UI", "line1\nline2", "a\r\nb", "x\n#already", "y\r!bang", "end\n",
            "caf\u00e9 \u20ac \u4e2d", "", "tab\there", "\u0001ctl"};
      try (PrintWriter w = writer("props_comments.txt")) {
         for (String c : comments) {
            ByteArrayOutputStream bos = new ByteArrayOutputStream();
            new Properties().store(bos, c);
            byte[] all = bos.toByteArray();
            String text = new String(all, StandardCharsets.ISO_8859_1);
            // drop the trailing "#<date>\n" line
            int end = text.lastIndexOf('#');
            String head = text.substring(0, end);
            w.print(hexUtf8(c) + "\t" + hex(head.getBytes(StandardCharsets.ISO_8859_1)) + "\n");
         }
      }
      // A full multi-entry file (lines compared as a set; order is Hashtable order).
      Properties all = new Properties();
      for (String[] kv : PROPS) all.setProperty(kv[0], kv[1]);
      try (FileOutputStream fos = new FileOutputStream(new File(out, "props_store.properties"))) {
         all.store(fos, "Settings for server UI");
      }

      // Load test: crafted input, Java's parsed result.
      String input = ""
            + "# comment line\n"
            + "! bang comment\n"
            + "   # indented comment\n"
            + "\n"
            + "   \t  \n"
            + "simple=value\n"
            + "colon:value2\n"
            + "space value3\n"
            + "tabsep\tvalue4\n"
            + "  leading.ws = spaced value  \n"
            + "eq.then.colon = :x\n"
            + "colon.then.eq : =y\n"
            + "noval\n"
            + "noval2=\n"
            + "escaped\\ key\\=x\\:y = v\\\\w\n"
            + "unicode\\u0041\\u00e9 = \\u20ac\\u001E\\u001f\n"
            + "cont = first \\\n"
            + "       second \\\r\n"
            + "\tthird\n"
            + "crlf = one\r\n"
            + "cr = two\r"
            + "esc = \\t\\n\\r\\f\\q\\z\n"
            + "dup = 1\n"
            + "dup = 2\n"
            + "even.backslash = a\\\\\n"
            + "after.even = b\n"
            + "comment.cont = c # not a comment\n"
            + "# comment ending in backslash \\\n"
            + "after.comment = d\n"
            + "latin = caf\u00e9\n"
            + "cont.blank = x\\\n"
            + "\n"
            + "after.blank = e\n"
            + "lastline.cont = f\\";
      byte[] inputBytes = input.getBytes(StandardCharsets.ISO_8859_1);
      writeBytes("props_load_input.properties", inputBytes);
      Properties loaded = new Properties();
      loaded.load(new ByteArrayInputStream(inputBytes));
      TreeMap<String, String> sorted = new TreeMap<>();
      for (String k : loaded.stringPropertyNames()) sorted.put(k, loaded.getProperty(k));
      try (PrintWriter w = writer("props_load_expected.txt")) {
         for (Map.Entry<String, String> e : sorted.entrySet()) {
            w.print(hexUtf8(e.getKey()) + "\t" + hexUtf8(e.getValue()) + "\n");
         }
      }
   }

   private static void dates() throws IOException {
      String[] zones = {"America/Los_Angeles", "America/New_York", "America/Chicago", "America/Denver", "UTC", "GMT",
            "Europe/London", "Europe/Berlin", "Asia/Tokyo", "Australia/Sydney"};
      long[] instants = {0L, 1700000000000L, 1720000000000L, 1767225599000L, 951782400000L};
      TimeZone saved = TimeZone.getDefault();
      try (PrintWriter w = writer("date_tostring.txt")) {
         for (String z : zones) {
            TimeZone.setDefault(TimeZone.getTimeZone(z));
            for (long t : instants) {
               w.print(z + "\t" + t + "\t" + new Date(t).toString() + "\n");
            }
         }
      } finally {
         TimeZone.setDefault(saved);
      }
   }

   // MARK: URLEncoder

   private static void urlCoding() throws IOException {
      String[] samples = {"Band SW", "Tower 40m", "a.b-c*d_e", "a+b=c&d", "caf\u00e9", "\u20ac", "~!@#$%^()",
            "\ud83d\ude00", "slash/back\\", "", " ", "tab\tnl\n", "\u001e\u001f", "6-Pack:2"};
      try (PrintWriter w = writer("url_encode.txt")) {
         for (String s : samples) {
            w.print(hexUtf8(s) + "\t" + URLEncoder.encode(s, "UTF-8") + "\n");
         }
      }
      String[] encoded = {"Band+SW", "caf%C3%A9", "caf%c3%a9", "%E2%82%AC", "a%2Bb", "%FF", "%C3", "plain",
            "%41%42", "100%25", "a*b.c-d_e~f"};
      try (PrintWriter w = writer("url_decode.txt")) {
         for (String s : encoded) {
            w.print(s + "\t" + hexUtf8(URLDecoder.decode(s, "UTF-8")) + "\n");
         }
      }
   }
}
