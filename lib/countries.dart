/// Country calling codes for the phone number field, and a basic check that a
/// number "looks right" (digits only, a plausible length for the country).
/// It does not call the number or send a code.
class Country {
  final String iso;
  final String name;
  final String dial;
  const Country(this.iso, this.name, this.dial);

  String get label => '+$dial';

  @override
  bool operator ==(Object other) => other is Country && other.iso == iso;

  @override
  int get hashCode => iso.hashCode;
}

const String _raw = '''
AF|Afghanistan|93
AL|Albania|355
DZ|Algeria|213
AS|American Samoa|1684
AD|Andorra|376
AO|Angola|244
AI|Anguilla|1264
AG|Antigua and Barbuda|1268
AR|Argentina|54
AM|Armenia|374
AW|Aruba|297
AU|Australia|61
AT|Austria|43
AZ|Azerbaijan|994
BS|Bahamas|1242
BH|Bahrain|973
BD|Bangladesh|880
BB|Barbados|1246
BY|Belarus|375
BE|Belgium|32
BZ|Belize|501
BJ|Benin|229
BM|Bermuda|1441
BT|Bhutan|975
BO|Bolivia|591
BA|Bosnia and Herzegovina|387
BW|Botswana|267
BR|Brazil|55
VG|British Virgin Islands|1284
BN|Brunei|673
BG|Bulgaria|359
BF|Burkina Faso|226
BI|Burundi|257
KH|Cambodia|855
CM|Cameroon|237
CA|Canada|1
CV|Cape Verde|238
KY|Cayman Islands|1345
CF|Central African Republic|236
TD|Chad|235
CL|Chile|56
CN|China|86
CO|Colombia|57
KM|Comoros|269
CG|Congo|242
CD|Congo (DR)|243
CK|Cook Islands|682
CR|Costa Rica|506
CI|Côte d'Ivoire|225
HR|Croatia|385
CU|Cuba|53
CW|Curaçao|599
CY|Cyprus|357
CZ|Czechia|420
DK|Denmark|45
DJ|Djibouti|253
DM|Dominica|1767
DO|Dominican Republic|1809
EC|Ecuador|593
EG|Egypt|20
SV|El Salvador|503
GQ|Equatorial Guinea|240
ER|Eritrea|291
EE|Estonia|372
SZ|Eswatini|268
ET|Ethiopia|251
FK|Falkland Islands|500
FO|Faroe Islands|298
FJ|Fiji|679
FI|Finland|358
FR|France|33
GF|French Guiana|594
PF|French Polynesia|689
GA|Gabon|241
GM|Gambia|220
GE|Georgia|995
DE|Germany|49
GH|Ghana|233
GI|Gibraltar|350
GR|Greece|30
GL|Greenland|299
GD|Grenada|1473
GP|Guadeloupe|590
GU|Guam|1671
GT|Guatemala|502
GG|Guernsey|44
GN|Guinea|224
GW|Guinea-Bissau|245
GY|Guyana|592
HT|Haiti|509
HN|Honduras|504
HK|Hong Kong|852
HU|Hungary|36
IS|Iceland|354
IN|India|91
ID|Indonesia|62
IR|Iran|98
IQ|Iraq|964
IE|Ireland|353
IM|Isle of Man|44
IL|Israel|972
IT|Italy|39
JM|Jamaica|1876
JP|Japan|81
JE|Jersey|44
JO|Jordan|962
KZ|Kazakhstan|7
KE|Kenya|254
KI|Kiribati|686
XK|Kosovo|383
KW|Kuwait|965
KG|Kyrgyzstan|996
LA|Laos|856
LV|Latvia|371
LB|Lebanon|961
LS|Lesotho|266
LR|Liberia|231
LY|Libya|218
LI|Liechtenstein|423
LT|Lithuania|370
LU|Luxembourg|352
MO|Macao|853
MG|Madagascar|261
MW|Malawi|265
MY|Malaysia|60
MV|Maldives|960
ML|Mali|223
MT|Malta|356
MH|Marshall Islands|692
MQ|Martinique|596
MR|Mauritania|222
MU|Mauritius|230
YT|Mayotte|262
MX|Mexico|52
FM|Micronesia|691
MD|Moldova|373
MC|Monaco|377
MN|Mongolia|976
ME|Montenegro|382
MS|Montserrat|1664
MA|Morocco|212
MZ|Mozambique|258
MM|Myanmar|95
NA|Namibia|264
NR|Nauru|674
NP|Nepal|977
NL|Netherlands|31
NC|New Caledonia|687
NZ|New Zealand|64
NI|Nicaragua|505
NE|Niger|227
NG|Nigeria|234
NU|Niue|683
NF|Norfolk Island|672
KP|North Korea|850
MK|North Macedonia|389
MP|Northern Mariana Islands|1670
NO|Norway|47
OM|Oman|968
PK|Pakistan|92
PW|Palau|680
PS|Palestine|970
PA|Panama|507
PG|Papua New Guinea|675
PY|Paraguay|595
PE|Peru|51
PH|Philippines|63
PL|Poland|48
PT|Portugal|351
PR|Puerto Rico|1787
QA|Qatar|974
RE|Réunion|262
RO|Romania|40
RU|Russia|7
RW|Rwanda|250
BL|Saint Barthélemy|590
SH|Saint Helena|290
KN|Saint Kitts and Nevis|1869
LC|Saint Lucia|1758
MF|Saint Martin|590
PM|Saint Pierre and Miquelon|508
VC|Saint Vincent and the Grenadines|1784
WS|Samoa|685
SM|San Marino|378
ST|São Tomé and Príncipe|239
SA|Saudi Arabia|966
SN|Senegal|221
RS|Serbia|381
SC|Seychelles|248
SL|Sierra Leone|232
SG|Singapore|65
SX|Sint Maarten|1721
SK|Slovakia|421
SI|Slovenia|386
SB|Solomon Islands|677
SO|Somalia|252
ZA|South Africa|27
KR|South Korea|82
SS|South Sudan|211
ES|Spain|34
LK|Sri Lanka|94
SD|Sudan|249
SR|Suriname|597
SE|Sweden|46
CH|Switzerland|41
SY|Syria|963
TW|Taiwan|886
TJ|Tajikistan|992
TZ|Tanzania|255
TH|Thailand|66
TL|Timor-Leste|670
TG|Togo|228
TK|Tokelau|690
TO|Tonga|676
TT|Trinidad and Tobago|1868
TN|Tunisia|216
TR|Türkiye|90
TM|Turkmenistan|993
TC|Turks and Caicos Islands|1649
TV|Tuvalu|688
UG|Uganda|256
UA|Ukraine|380
AE|United Arab Emirates|971
GB|United Kingdom|44
US|United States|1
UY|Uruguay|598
UZ|Uzbekistan|998
VU|Vanuatu|678
VA|Vatican City|379
VE|Venezuela|58
VN|Vietnam|84
VI|US Virgin Islands|1340
WF|Wallis and Futuna|681
EH|Western Sahara|212
YE|Yemen|967
ZM|Zambia|260
ZW|Zimbabwe|263
''';

final List<Country> kCountries = () {
  final list = <Country>[];
  for (final line in _raw.split('\n')) {
    final p = line.trim().split('|');
    if (p.length != 3) continue;
    list.add(Country(p[0], p[1], p[2]));
  }
  list.sort((a, b) => a.name.compareTo(b.name));
  return List<Country>.unmodifiable(list);
}();

Country countryByIso(String? iso, {String fallback = 'LT'}) {
  return kCountries.firstWhere(
    (c) => c.iso == iso,
    orElse: () => kCountries.firstWhere((c) => c.iso == fallback),
  );
}

/// Digits of the national number (after the country code, without the
/// leading 0 some countries write in front). "min max" per country; a single
/// number means exactly that many digits.
const String _lenRaw = '''
AF 9
AL 8 9
DZ 8 9
AS 10
AD 6 9
AO 9
AI 10
AG 10
AR 10 11
AM 8
AW 7
AU 9
AT 7 13
AZ 9
BS 10
BH 8
BD 8 10
BB 10
BY 9
BE 8 9
BZ 7
BJ 8 10
BM 10
BT 8
BO 8
BA 8
BW 7 8
BR 10 11
VG 10
BN 7
BG 8 9
BF 8
BI 8
KH 8 9
CM 9
CA 10
CV 7
KY 10
CF 8
TD 8
CL 9
CN 10 11
CO 10
KM 7
CG 9
CD 9
CK 5
CR 8
CI 10
HR 8 9
CU 8
CW 7 8
CY 8
CZ 9
DK 8
DJ 8
DM 10
DO 10
EC 8 9
EG 9 10
SV 8
GQ 9
ER 7
EE 7 8
SZ 8
ET 9
FK 5
FO 6
FJ 7
FI 6 12
FR 9
GF 9
PF 8
GA 7 8
GM 7
GE 9
DE 7 13
GH 9
GI 8
GR 10
GL 6
GD 10
GP 9
GU 10
GT 8
GG 10
GN 9
GW 7 9
GY 7
HT 8
HN 8
HK 8
HU 8 9
IS 7
IN 10
ID 8 12
IR 10
IQ 10
IE 7 9
IM 10
IL 8 9
IT 6 11
JM 10
JP 9 10
JE 10
JO 8 9
KZ 10
KE 9
KI 5 8
XK 8 9
KW 8
KG 9
LA 8 10
LV 8
LB 7 8
LS 8
LR 7 9
LY 9 10
LI 7 9
LT 8
LU 6 11
MO 8
MG 9
MW 7 9
MY 7 10
MV 7
ML 8
MT 8
MH 7
MQ 9
MR 8
MU 7 8
YT 9
MX 10
FM 7
MD 8
MC 8 9
MN 8
ME 8
MS 10
MA 9
MZ 9
MM 7 10
NA 7 9
NR 7
NP 8 10
NL 9
NC 6
NZ 8 10
NI 8
NE 8
NG 7 10
NU 4
NF 6
KP 8 10
MK 8
MP 10
NO 8
OM 8
PK 9 10
PW 7
PS 8 9
PA 7 8
PG 7 8
PY 8 9
PE 8 9
PH 8 10
PL 9
PT 9
PR 10
QA 8
RE 9
RO 9
RU 10
RW 9
BL 9
SH 4 5
KN 10
LC 10
MF 9
PM 6
VC 10
WS 5 7
SM 6 10
ST 7
SA 9
SN 9
RS 8 9
SC 7
SL 8
SG 8
SX 10
SK 9
SI 8
SB 5 7
SO 7 9
ZA 9
KR 8 10
SS 9
ES 9
LK 9
SD 9
SR 6 7
SE 7 10
CH 9
SY 8 9
TW 8 9
TJ 9
TZ 9
TH 8 9
TL 7 8
TG 8
TK 4
TO 5 7
TT 10
TN 8
TR 10
TM 8
TC 10
TV 5 6
UG 9
UA 9
AE 8 9
GB 9 10
US 10
UY 8
UZ 9
VU 5 7
VA 6 10
VE 10
VN 9 10
VI 10
WF 6
EH 9
YE 7 9
ZM 9
ZW 7 9
''';

final Map<String, (int, int)> _lengths = () {
  final m = <String, (int, int)>{};
  for (final line in _lenRaw.split('\n')) {
    final p = line.trim().split(' ');
    if (p.length < 2) continue;
    final lo = int.parse(p[1]);
    final hi = p.length > 2 ? int.parse(p[2]) : lo;
    m[p[0]] = (lo, hi);
  }
  return m;
}();

/// Only the digits of what was typed.
String phoneDigits(String input) => input.replaceAll(RegExp(r'[^0-9]'), '');

/// The number as it is saved: digits only, and without the trunk "0" many
/// countries write in front (05XXXXXXXX in Saudi Arabia is saved as
/// 5XXXXXXXX). The 0 is only dropped when that makes the length right.
String normalizePhone(Country country, String input) {
  var digits = phoneDigits(input);
  final range = _lengths[country.iso] ?? (4, 14);
  if (digits.startsWith('0') && digits.length > range.$2) {
    final cut = digits.substring(1);
    if (cut.length >= range.$1 && cut.length <= range.$2) digits = cut;
  }
  return digits;
}

/// Null when the number looks right for [country], otherwise what is wrong.
String? validatePhone(Country country, String input) {
  final raw = input.trim();
  if (raw.isEmpty) return 'Enter your phone number';
  if (raw.startsWith('+') || raw.startsWith('00')) {
    return 'Enter the number without the country code';
  }
  if (!RegExp(r'^[0-9 ()\-.]+$').hasMatch(raw)) {
    return 'Use digits only';
  }
  final digits = normalizePhone(country, raw);
  final range = _lengths[country.iso] ?? (4, 14);
  if (digits.length < range.$1 || digits.length > range.$2) {
    return range.$1 == range.$2
        ? '${country.name} numbers have ${range.$1} digits after ${country.label}'
        : '${country.name} numbers have ${range.$1} to ${range.$2} digits after ${country.label}';
  }
  if (country.dial.length + digits.length > 15) {
    return 'This number is too long';
  }
  return null;
}