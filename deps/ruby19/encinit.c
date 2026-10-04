/* encinit.c (Ruby 1.9): links the encodings and transcoders that
 * Ruby 1.9 loads from enc/*.so and enc/trans/*.so. iOS cannot dlopen
 * them, and 1.9.3 has no static build of them. Without this file the
 * VM knows only ASCII-8BIT, UTF-8 and US-ASCII, has no Encoding::UTF_8
 * constant, and String#encode cannot convert to UTF-16.
 *
 * The build compiles each enc/trans/X.c with -DInit_X=Init_trans_X,
 * because enc/big5.c and enc/trans/big5.c (and gb18030, gbk) both
 * define Init_X.
 *
 * Order matters. encdb declares every name, so an encoding file can
 * register over its placeholder. gb2312 looks up EUC-KR, so euc_kr
 * comes first. transdb records a library name per converter. A
 * converter registered after that is used as is, and never loads the
 * library. */

void ruby_init_ext(const char *name, void (*init)(void));

void Init_encdb(void);
void Init_big5(void);
void Init_big5_hkscs(void);
void Init_big5_uao(void);
void Init_cp949(void);
void Init_emacs_mule(void);
void Init_euc_jp(void);
void Init_euc_kr(void);
void Init_euc_tw(void);
void Init_gb18030(void);
void Init_gb2312(void);
void Init_gbk(void);
void Init_iso_8859_1(void);
void Init_iso_8859_10(void);
void Init_iso_8859_11(void);
void Init_iso_8859_13(void);
void Init_iso_8859_14(void);
void Init_iso_8859_15(void);
void Init_iso_8859_16(void);
void Init_iso_8859_2(void);
void Init_iso_8859_3(void);
void Init_iso_8859_4(void);
void Init_iso_8859_5(void);
void Init_iso_8859_6(void);
void Init_iso_8859_7(void);
void Init_iso_8859_8(void);
void Init_iso_8859_9(void);
void Init_koi8_r(void);
void Init_koi8_u(void);
void Init_shift_jis(void);
void Init_utf_16be(void);
void Init_utf_16le(void);
void Init_utf_32be(void);
void Init_utf_32le(void);
void Init_windows_1251(void);
void Init_transdb(void);
void Init_trans_big5(void);
void Init_trans_chinese(void);
void Init_trans_emoji(void);
void Init_trans_emoji_iso2022_kddi(void);
void Init_trans_emoji_sjis_docomo(void);
void Init_trans_emoji_sjis_kddi(void);
void Init_trans_emoji_sjis_softbank(void);
void Init_trans_escape(void);
void Init_trans_gb18030(void);
void Init_trans_gbk(void);
void Init_trans_iso2022(void);
void Init_trans_japanese(void);
void Init_trans_japanese_euc(void);
void Init_trans_japanese_sjis(void);
void Init_trans_korean(void);
void Init_trans_single_byte(void);
void Init_trans_utf8_mac(void);
void Init_trans_utf_16_32(void);

/* enc/big5.c defines three encodings. Loaded as big5.so, Ruby would
 * run only Init_big5. */
static void Init_big5_all(void)
{
    Init_big5();
    Init_big5_hkscs();
    Init_big5_uao();
}

void mkxp_ruby19_init_encodings(void)
{
    ruby_init_ext("enc/encdb.so", Init_encdb);
    ruby_init_ext("enc/big5.so", Init_big5_all);
    ruby_init_ext("enc/cp949.so", Init_cp949);
    ruby_init_ext("enc/emacs_mule.so", Init_emacs_mule);
    ruby_init_ext("enc/euc_jp.so", Init_euc_jp);
    ruby_init_ext("enc/euc_kr.so", Init_euc_kr);
    ruby_init_ext("enc/euc_tw.so", Init_euc_tw);
    ruby_init_ext("enc/gb18030.so", Init_gb18030);
    ruby_init_ext("enc/gb2312.so", Init_gb2312);
    ruby_init_ext("enc/gbk.so", Init_gbk);
    ruby_init_ext("enc/iso_8859_1.so", Init_iso_8859_1);
    ruby_init_ext("enc/iso_8859_10.so", Init_iso_8859_10);
    ruby_init_ext("enc/iso_8859_11.so", Init_iso_8859_11);
    ruby_init_ext("enc/iso_8859_13.so", Init_iso_8859_13);
    ruby_init_ext("enc/iso_8859_14.so", Init_iso_8859_14);
    ruby_init_ext("enc/iso_8859_15.so", Init_iso_8859_15);
    ruby_init_ext("enc/iso_8859_16.so", Init_iso_8859_16);
    ruby_init_ext("enc/iso_8859_2.so", Init_iso_8859_2);
    ruby_init_ext("enc/iso_8859_3.so", Init_iso_8859_3);
    ruby_init_ext("enc/iso_8859_4.so", Init_iso_8859_4);
    ruby_init_ext("enc/iso_8859_5.so", Init_iso_8859_5);
    ruby_init_ext("enc/iso_8859_6.so", Init_iso_8859_6);
    ruby_init_ext("enc/iso_8859_7.so", Init_iso_8859_7);
    ruby_init_ext("enc/iso_8859_8.so", Init_iso_8859_8);
    ruby_init_ext("enc/iso_8859_9.so", Init_iso_8859_9);
    ruby_init_ext("enc/koi8_r.so", Init_koi8_r);
    ruby_init_ext("enc/koi8_u.so", Init_koi8_u);
    ruby_init_ext("enc/shift_jis.so", Init_shift_jis);
    ruby_init_ext("enc/utf_16be.so", Init_utf_16be);
    ruby_init_ext("enc/utf_16le.so", Init_utf_16le);
    ruby_init_ext("enc/utf_32be.so", Init_utf_32be);
    ruby_init_ext("enc/utf_32le.so", Init_utf_32le);
    ruby_init_ext("enc/windows_1251.so", Init_windows_1251);
    ruby_init_ext("enc/trans/transdb.so", Init_transdb);
    ruby_init_ext("enc/trans/big5.so", Init_trans_big5);
    ruby_init_ext("enc/trans/chinese.so", Init_trans_chinese);
    ruby_init_ext("enc/trans/emoji.so", Init_trans_emoji);
    ruby_init_ext("enc/trans/emoji_iso2022_kddi.so", Init_trans_emoji_iso2022_kddi);
    ruby_init_ext("enc/trans/emoji_sjis_docomo.so", Init_trans_emoji_sjis_docomo);
    ruby_init_ext("enc/trans/emoji_sjis_kddi.so", Init_trans_emoji_sjis_kddi);
    ruby_init_ext("enc/trans/emoji_sjis_softbank.so", Init_trans_emoji_sjis_softbank);
    ruby_init_ext("enc/trans/escape.so", Init_trans_escape);
    ruby_init_ext("enc/trans/gb18030.so", Init_trans_gb18030);
    ruby_init_ext("enc/trans/gbk.so", Init_trans_gbk);
    ruby_init_ext("enc/trans/iso2022.so", Init_trans_iso2022);
    ruby_init_ext("enc/trans/japanese.so", Init_trans_japanese);
    ruby_init_ext("enc/trans/japanese_euc.so", Init_trans_japanese_euc);
    ruby_init_ext("enc/trans/japanese_sjis.so", Init_trans_japanese_sjis);
    ruby_init_ext("enc/trans/korean.so", Init_trans_korean);
    ruby_init_ext("enc/trans/single_byte.so", Init_trans_single_byte);
    ruby_init_ext("enc/trans/utf8_mac.so", Init_trans_utf8_mac);
    ruby_init_ext("enc/trans/utf_16_32.so", Init_trans_utf_16_32);
}
