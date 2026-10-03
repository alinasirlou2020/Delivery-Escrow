# DeliveryEscrow — پروتکل اسکرو تحویل کالای فیزیکی روی بلاکچین

> ساخته‌شده برای طرح Postex و پهباد بابک بانجانی (اکوسیستم DotOne / توکن DOTO)
> نسخه: MVP قابل تست و دمو — Foundry / Solidity 0.8.24

این ریپو نسخه‌ی کامل و کامپایل‌شده + تست‌شده (۴۸ تست پاس، همه‌ی مسیرها) از قراردادی است که از روی OnChainLotteryEscrow.sol بازطراحی شده: لایه‌ی لاتاری و Chainlink VRF کاملاً حذف شده و منطق اسکرو/حمل‌ونقل/OTP/دیسپیوت از حالت «یک لاتاری، یک برنده» به «N سفارش مستقل، هرکدام با خریدار/فروشنده/مهلت/روش تحویل خودش» تعمیم داده شده است.

---

## 1. فایل‌ها

```
src/
  DeliveryEscrow.sol       - قرارداد اصلی اسکرو (چند-سفارشی)
  IDeliveryEscrow.sol      - اینترفیس عمومی (برای اوراکل و ادغام‌های آینده)
  MockDeliveryOracle.sol   - اوراکل نمایشی برای MVP، جایگزین لایه‌ی off-chain واقعی
test/
  DeliveryEscrow.t.sol     - 48 تست Foundry (happy path، خطاها، امنیت، reentrancy)
  mocks/MockERC20.sol      - توکن تستی به‌جای DOTO
  mocks/ReentrantERC20.sol - توکن مخرب برای اثبات محافظت reentrancy
script/
  Deploy.s.sol             - اسکریپت دیپلوی (Anvil محلی یا هر شبکه‌ی EVM)
foundry.toml, remappings.txt
```

اجرا:
```bash
forge install OpenZeppelin/openzeppelin-contracts
forge build
forge test -vv
```

نکته فنی: چون Order استراکت بزرگی است، گتر خودکار مپینگ عمومی با optimizer پیش‌فرض به خطای "stack too deep" می‌خورد؛ به همین دلیل via_ir = true در foundry.toml فعال است. این کاملاً استاندارد و بی‌خطر است، فقط زمان کامپایل را کمی بیشتر می‌کند.

---

## 2. چرا این معماری؟ خلاصه‌ی تصمیم‌های طراحی

ایده‌ی اصلی شما در توضیحات پروژه دقیقاً همین بود و عیناً همان پیاده شده:

رویداد تحویل فیزیکی -> اطلاعات تحویل تأییدشده -> تأیید رمزنگاری‌شده/آن‌چین -> تسویه‌ی اسکرو

نکات کلیدی طراحی:

- قرارداد هرگز مستقیماً به GPS، حسگر، دوربین یا API لجستیک دسترسی ندارد. این محدودیت بنیادین بلاکچین است، نه یک ضعف طراحی. تنها راه ارتباط، یک آدرس deliveryOracle مجاز است که نتیجه‌ی نهایی و تأییدشده را آن‌چین می‌فرستد.
- فروشنده به‌تنهایی نمی‌تواند با دانستن OTP پول را آزاد کند، برخلاف قرارداد اصلی که releaseWithOtp را خود فروشنده صدا می‌زد. این‌جا فقط deliveryOracle می‌تواند confirmDelivery را صدا بزند و OTP هم فقط بخشی از اثبات است، نه کل اثبات.
- OTP هرگز روی چین ذخیره نمی‌شود، فقط keccak256(otp, orderId, address(this)). باند کردن به orderId و آدرس قرارداد از replay بین سفارش‌ها و بین دیپلوی‌های مختلف جلوگیری می‌کند؛ تست test_otp_isBoundToOrderId_preventsReplayAcrossOrders این را اثبات می‌کند.
- الگوی fixed-destination برای پول: در refundOrder و autoRelease هرکسی می‌تواند تابع را صدا بزند، اما پول همیشه فقط به آدرس ثابتِ buyer یا seller همان سفارش می‌رود، یعنی هیچ کاربری با صدا زدن تابع نمی‌تواند پول کاربر دیگر را بردارد؛ تست test_sellerCannotClaimBuyersRefund این را تضمین می‌کند.
- checks-effects-interactions به‌علاوه‌ی nonReentrant در همه‌ی توابعی که پول جابه‌جا می‌کنند: وضعیت سفارش قبل از safeTransfer تغییر می‌کند، بعد ReentrancyGuard هم یک لایه‌ی دفاعی دوم است. تست test_releaseFunds_isProtectedAgainstReentrancy با یک توکن مخرب واقعی این را امتحان می‌کند، نه فقط ادعا.
- سه مهلت جدا از هم، برخلاف قرارداد اصلی که شیپینگ و دلیوری را با یک تایم‌لاک قاطی کرده بود: SHIPPING_WINDOW، DELIVERY_WINDOW، DISPUTE_WINDOW. این دقیقاً چیزی است که در بخش ۲۳ توضیحات‌تان خواسته شده بود.
- دو مسیر settlement مجزا: releaseFunds که خریدار خودش زودتر تأیید می‌کند، و autoRelease که اگر خریدار کاری نکرد و پنجره‌ی دیسپیوت گذشت، هرکسی می‌تواند تریگر کند. این نسخه‌ی چندسفارشیِ همان دوگانه‌ی releaseWithOtp و autoReleaseFunds در قرارداد لاتاری است.

---

## 3. ماشین حالت هر سفارش

```
Created -> Funded -> Shipped -> OutForDelivery -> Delivered -> Completed
              |         |            |               |
              |         +------------+---------------+--> Disputed -> (Completed | Refunded)
              |
              +--(مهلت شیپینگ گذشت)--> Cancelled -> Refunded
```

نکته‌ی عملی: confirmDelivery هم از Shipped و هم از OutForDelivery قابل صدا زدن است، چون تحویل نقطه‌ی جمع‌آوری (Pickup Point) ممکن است اصلاً مرحله‌ی «در حال تحویل» نداشته باشد.

---

## 4. توابع اصلی (خلاصه)

| تابع | مجاز به صدا زدن | شرط | اثر |
|---|---|---|---|
| createOrder | خریدار یا فروشنده | آدرس‌ها معتبر، مبلغ بزرگ‌تر از صفر | سفارش جدید در Created |
| fundOrder | فقط خریدار | state == Created | انتقال ERC-20، state -> Funded |
| shipOrder | فقط فروشنده | state == Funded | ثبت tracking، مهلت تحویل ست می‌شود |
| markOutForDelivery | فقط deliveryOracle | state == Shipped | state -> OutForDelivery |
| confirmDelivery | فقط deliveryOracle | Shipped یا OutForDelivery | بررسی OTP در صورت وجود، state -> Delivered |
| releaseFunds | فقط خریدار | state == Delivered | پول به فروشنده، state -> Completed |
| autoRelease | هرکسی | Delivered و گذشتن DISPUTE_WINDOW | پول به فروشنده |
| reportNotShipped | فقط خریدار | Funded و گذشتن SHIPPING_WINDOW | state -> Cancelled |
| refundOrder | هرکسی | state == Cancelled | پول به خریدار |
| raiseDispute | فقط خریدار | Shipped/OutForDelivery/Delivered | state -> Disputed |
| resolveDispute | فقط arbiter | state == Disputed | پول به فروشنده یا خریدار |
| cancelUnfundedOrder | خریدار یا فروشنده | state == Created | state -> Cancelled بدون جابه‌جایی پول |

---

## 5. اوراکل تحویل: امروز Mock، فردا واقعی

این مهم‌ترین بخش برای شما به‌عنوان توسعه‌دهنده‌ی وب۳ پروژه است، چون جایی که مسئولیت شما شروع می‌شود دقیقاً همین‌جاست.

### امروز (MVP)

deliveryOracle یک آدرس واحد است. در تست‌ها MockDeliveryOracle.sol یک قرارداد ساده با onlyOwner است که فراخوانی‌ها را به DeliveryEscrow فوروارد می‌کند. این دقیقاً همان چیزی است که طراحی خواسته بود: بدون نیاز به شبکه‌ی اوراکل غیرمتمرکز واقعی، کل چرخه‌ی تحویل قابل نمایش باشد.

### نقشه‌راه واقعی (GPS، پهباد، پیک انسانی)

معماری درستی که در بخش‌های ۱۸، ۳۴ و ۳۵ توضیحات شما هم تأکید شده و باید حتماً حفظ شود:

```
پهباد یا پیک  ->  تله‌متری/GPS/اپ تحویل  ->  پلتفرم تحویل (Postex backend)
                                                  |
                                      تأیید (geofence, OTP, timestamp, sensor)
                                                  |
                                         امضای اثبات (attestation) با کلید خصوصی
                                                  |
                                           ارسال تراکنش آن‌چین
                                                  |
                                       DeliveryEscrow.confirmDelivery()
```

قرارداد هوشمند هیچ‌وقت نباید مستقیم با GPS یا پهباد صحبت کند — این یک اصل معماری است، نه محدودیت موقت. کاری که باید در فازهای بعدی ساخته شود:

### فاز A: سرویس بک‌اند تحویل (خارج از چین)

یک سرویس (می‌تواند Node.js یا Go باشد) که:

1. از اپ پیک یا فرم‌ور پهباد، رویدادهای خام دریافت می‌کند: مختصات GPS، timestamp، شناسه‌ی shipment، عکس یا حسگر drop-off، و در صورت پیک انسانی OTP واردشده توسط گیرنده.
2. یک ژئوفنس را چک می‌کند: مختصات دریافتی باید در شعاع مشخصی از آدرس مقصد ثبت‌شده باشد، مثلاً کمتر از ۵۰ متر.
3. نتیجه را به‌صورت یک struct امضا می‌کند. EIP-712 پیشنهاد می‌شود، چون در کیف‌پول‌ها و ابزارهای وب۳ خوانا و استاندارد است:

```solidity
struct DeliveryAttestation {
    uint256 orderId;
    address escrowContract;
    uint256 chainId;
    bytes32 shipmentHash;   // hash روی shipmentId
    int256 lat;              // مقیاس‌شده، مثلا ضرب‌در ۱۰ به توان ۶
    int256 lon;
    uint256 timestamp;
    uint256 nonce;           // جلوگیری از replay
}
```

4. امضا را همراه داده به یک relayer می‌دهد که تراکنش confirmDelivery(orderId, proof) را می‌فرستد. proof در این فاز به‌جای رشته‌ی OTP، abi.encode(attestation, signature) خواهد بود.

### فاز B: قرارداد وارث DeliveryEscrow با verifier امضا

به‌جای MockDeliveryOracle، یک قرارداد جدید مثلاً SignedAttestationOracle.sol می‌نویسید که:

- کلید عمومی امضاکننده یا چند کلید، برای چند اپراتور لجستیک، را نگه می‌دارد.
- در confirmDelivery، ECDSA.recover را روی DeliveryAttestation اجرا می‌کند، chainId و escrowContract و nonce را چک می‌کند؛ دقیقاً چیزی که بخش ۲۷ توضیحات شما زیر «Replay protection» خواسته، و فقط در صورت معتبر بودن امضا، متد confirmDelivery واقعی روی DeliveryEscrow را صدا می‌زند.
- چون DeliveryEscrow.deliveryOracle فقط یک آدرس است، جایگزین کردن MockDeliveryOracle با این قرارداد جدید هیچ تغییری در DeliveryEscrow.sol نمی‌خواهد. همین قابلیت جایگزینی، دلیل اصلی طراحی لایه‌ای بود.

### فاز C: چند اوراکل یا چند امضا (اختیاری، فاز بلندمدت)

اگر خواستید اعتماد را از «یک سرویس بک‌اند» به «چند اپراتور مستقل» ببرید، مثلاً هم پلتفرم لجستیک هم پهباد هم گیرنده باید امضا کنند، SignedAttestationOracle را به یک آستانه‌ی چند-امضایی (m-of-n) ارتقا دهید. این دقیقاً همان چیزی است که بخش ۳۷ توضیحات شما به‌عنوان «چند اثبات تحویل که در attestation نهایی سهیم‌اند» توصیف کرده.

### داده‌های GPS دقیقاً کجا می‌روند؟

هرگز روی چین ذخیره نمی‌شوند خام. فقط:

- یا در همان DeliveryAttestation امضاشده به‌صورت پارامتر تراکنش (calldata) قرار می‌گیرند؛ که روی چین وجود دارد اما به‌صورت ورودی یک تابع، نه یک متغیر storage. برای اثبات بعدی (auditing) کافی است چون تراکنش در تاریخچه‌ی چین باقی می‌ماند.
- یا فقط یک هش از بسته‌ی کامل داده‌های حسگر (shipmentHash) روی چین می‌رود و خودِ داده‌ی خام (تصویر drop-off، مسیر کامل GPS) در یک استوریج off-chain مثل IPFS یا Arweave یا دیتابیس Postex نگه داشته می‌شود. این الگو، یعنی commit روی چین به‌همراه داده روی IPFS، هم گس کمتری مصرف می‌کند هم استاندارد صنعت است.

---

## 6. پهباد در مقابل پیک انسانی: چرا قرارداد فرقی نمی‌گذارد

دقیقاً طبق بخش ۳۵ توضیحات‌تان، تفاوت پهباد و پیک فقط در لایه‌ی off-chain است، نه در قرارداد.

```
پهباد:  Warehouse -> Drone dispatched -> markOutForDelivery -> Geofence+Drop confirm -> confirmDelivery
پیک:    Warehouse -> Courier receives -> markOutForDelivery -> OTP از گیرنده         -> confirmDelivery
پیکاپ:  Warehouse -> (این مرحله معمولا حذف می‌شود)             -> کد QR در ترمینال     -> confirmDelivery
```

enum DeliveryMethod فقط برچسب اطلاعاتی است؛ منطق آن‌چین برای هر سه یکسان است. این یعنی می‌توانید فرم‌ور پهباد بابک بانجانی را کاملاً مستقل از این قرارداد توسعه دهید — تنها قراردادی که باید حفظ شود، شکل خروجی attestation است (فاز A بالا).

---

## 7. چک‌لیست امنیتی که پیاده‌سازی شده

- انجام‌شده: Reentrancy با ReentrancyGuard به‌علاوه‌ی الگوی effects-before-interactions در همه‌ی مسیرهای پرداخت، تست‌شده با توکن مخرب واقعی.
- انجام‌شده: SafeERC20 برای همه‌ی انتقال‌ها.
- انجام‌شده: اعتبارسنجی state در هر تابع state-changing با modifier مخصوص.
- انجام‌شده: جداسازی نقش‌ها — خریدار، فروشنده، اوراکل، آربیتر و owner هیچ‌کدام جای هم را نمی‌گیرند.
- انجام‌شده: OTP هرگز plaintext ذخیره یا emit نمی‌شود؛ hash به orderId و آدرس قرارداد باند است.
- انجام‌شده: الگوی fixed-destination برای refund/release، یعنی کاربر نمی‌تواند پول کاربر دیگر را بردارد.
- انجام‌شده: آدرس صفر و مقدار صفر در createOrder و constructor رد می‌شوند.
- ناقص عمدی: Replay protection کامل یعنی nonce به‌همراه امضا هنوز در سطح فاز B/C پیاده می‌شود. در MVP فعلی روی OTP hash و کنترل state تکیه شده که برای دمو کافی است اما جایگزین امضای رمزنگاری‌شده نیست.

---

## 8. چیزهایی که عمداً هنوز ساخته نشده‌اند

طبق بخش ۳۸ توضیحات شما، این‌ها آگاهانه از این فاز حذف شده‌اند و در فازهای بعدی می‌آیند: فرم‌ور واقعی پهباد، اتصال واقعی GPS، API واقعی لجستیک، شبکه‌ی اوراکل غیرمتمرکز، حاکمیت DAO، سیستم اعتبار (reputation)، چندزنجیره‌ای، ریل‌های پرداخت فیات، تبدیل استیبل‌کوین، KYC کامل، اثبات‌های zero-knowledge.

نقشه‌راه فازبندی پیشنهادی، مطابق بخش ۳۹ توضیحات‌تان، که همین الان در همین ریپو تا فاز ۷ انجام شده:

| فاز | وضعیت | توضیح |
|---|---|---|
| ۱ تا ۶ | انجام‌شده | قرارداد کامل، همه‌ی توابع، امنیت، OTP |
| ۷ | انجام‌شده | تست‌های Foundry، ۴۸ تست |
| ۸ | نوبت شما | دیپلوی روی Anvil محلی با forge script script/Deploy.s.sol --rpc-url ... --broadcast |
| ۹ | نوبت شما | دیپلوی روی تست‌نت DotOne، فقط بعد از تأیید آدرس واقعی توکن DOTO و RPC |
| A تا C در بخش ۵ این فایل | آینده | جایگزینی MockDeliveryOracle با سرویس attestation امضاشده متصل به GPS/پهباد واقعی |

---

## 9. یک نکته‌ی مهم برای ارائه‌ی پروژه

طبق بخش ۳۷ توضیحات خودتان، این پروژه را این‌طور معرفی نکنید: «قراردادی که با واردکردن OTP پول را آزاد می‌کند».

بلکه: «لایه‌ی اسکرو بلاکچینی که تأیید تحویل فیزیکی را به تسویه‌ی مالی خودکار وصل می‌کند». OTP فقط یکی از چند اثبات ممکن تحویل است؛ معماری از روز اول برای پذیرفتن اثبات‌های چندگانه (GPS، امضای دستگاه، ژئوفنس) طراحی شده، نه فقط یک رمز یک‌بار مصرف.

---

## 10. اجرای سریع دمو (سناریوی کامل بخش ۳۱ توضیحات شما)

```solidity
// 1) ساخت سفارش - فروشنده صدا می‌زند
uint256 id = escrow.createOrder(seller, buyer, 100e18, DeliveryMethod.DRONE, otpHash, "shipment-1");

// 2) تامین مالی - خریدار
escrow.fundOrder(id);

// 3) ارسال - فروشنده
escrow.shipOrder(id, "TRACK-XYZ");

// 4) دیسپچ پهباد - از طریق MockDeliveryOracle
mockOracle.markOutForDelivery(id);

// 5) تایید تحویل (OTP یا اثبات دیگر) - از طریق MockDeliveryOracle
mockOracle.confirmDelivery(id, abi.encode("123456"));

// 6) تسویه - خریدار زودتر تایید می‌کند، یا بعد از DISPUTE_WINDOW هرکسی autoRelease می‌زند
escrow.releaseFunds(id); // یا escrow.autoRelease(id);
```

سناریوهای شکست هم در تست‌ها پوشش داده شده‌اند: عدم ارسال به‌موقع از طریق reportNotShipped به‌همراه refundOrder، و دیسپیوت از طریق raiseDispute به‌همراه resolveDispute توسط آربیتر.


# DeliveryEscrow — معماری نهایی دلیوری روی بلاکچین

> نسخه: معماری نهایی (Final Delivery Architecture) — Foundry / Solidity 0.8.24
> ۵۱ تست پاس، شامل سناریوهای شکست، حادثه، مرجوعی و دیسپیوت

این نسخه دقیقاً طبق `Final_Delivery_Architecture_Specification_for_DeliveryEscrow.md` بازنویسی شده. تنها فایل سالیدیتیِ اصلی (`src/DeliveryEscrow.sol`) به‌صورت جوهری تغییر کرده؛ `IDeliveryEscrow.sol` و `MockDeliveryOracle.sol` هم چون امضای توابع عوض شده (به‌خصوص `confirmDelivery`) به‌روزرسانی شدند تا کامپایل و تست‌ها سالم بمانند — دقیقاً همان چیزی که خواسته بودید.

---

## 1. جواب مستقیم به سوال شما: سناریوها کافی هستن؟

**بله، با یک اضافه‌ی کوچک که خودم در حین پیاده‌سازی اضافه کردم.** جدول زیر هر سناریوی مشخص‌شده در سند نهایی را به کد واقعی مپ می‌کند:

| سناریوی سند | بخش | پیاده‌سازی در کد |
|---|---|---|
| تحویل موفق | ۴، ۱۳ | `Funded→Shipped→OutForDelivery→Delivered→Completed` (بدون تغییر نسبت به قبل) |
| خرابی پهباد وسط راه | ۱۴ | `reportDeliveryIncident(DeliveryFailed)` → `Disputed` → آربیتر می‌تواند `Reship` بزند (نه فقط رفاند) |
| تصادف وسیله‌ی نقلیه | ۱۵ | همان مسیر `reportDeliveryIncident` با `evidenceRef` |
| گم‌شدن بسته | ۱۶ | `reportDeliveryIncident(PackageLost)` → `Disputed` → معمولاً `RefundBuyer` |
| بسته‌ی آسیب‌دیده | ۱۷ | `raiseDispute(PackageDamaged, evidenceRef)` توسط خریدار، بعد از `Delivered` |
| کالای اشتباه | ۱۸ | `raiseDispute(WrongPackage, ...)` → آربیتر → `ApproveReturn` → `Returning` → `confirmReturnReceived` → `Refunded` |
| رد بسته توسط خریدار | ۱۹ | `raiseDispute(BuyerRejected, ...)`؛ تشخیص «رد موجه در برابر ناموجه» عمداً آن‌چین نیست، چون قرارداد نمی‌تواند صحت فیزیکی کالا را بسنجد — این دقیقاً همان چیزی است که سند در بخش ۱۸/۱۹ می‌گوید و باید به آربیتر واگذار شود |
| مرجوعی موفق | ۲۰ | `Disputed→Returning` (توسط آربیتر) → `confirmReturnReceived` (توسط اوراکل) → `Refunded` مستقیم |
| گم‌شدن مرجوعی | ۲۱ | `reportDeliveryIncident` حالا از `Returning` هم مجاز است → دوباره `Disputed` |
| تأخیر بدون گم‌شدن | ۲۲ | هیچ state جدیدی اضافه نشده؛ سفارش در `Shipped`/`OutForDelivery` می‌ماند تا `reportDeliveryTimeout` (تابع جدید) توسط خریدار فعال شود |
| مهلت تحویل | ۲۳ | `deliveryDeadline` هست، اما **به‌تنهایی هرگز پول را آزاد نمی‌کند** — فقط `reportDeliveryTimeout` را باز می‌کند که خودش هم فقط `Disputed` می‌سازد، نه پرداخت |
| آزادسازی خودکار | ۲۴ | `autoRelease` فقط از `Delivered` کار می‌کند، هرگز از انقضای صرفِ deadline |
| رفع دیسپیوت | ۲۵ | `resolveDispute` سه‌حالته (`RefundBuyer` / `PaySeller` / `ApproveReturn`) + یک حالت چهارم که خودم اضافه کردم: `Reship` |

**چیزی که من اضافه کردم و در enum سند نبود:** سند در بخش ۱۴ صراحتاً می‌گوید یکی از خروجی‌های ممکنِ حادثه‌ی «خرابی پهباد» می‌تواند «Reship / retry delivery» باشد، نه فقط رفاند. در enum بخش ۲۵ سند فقط سه حالت (`RefundBuyer`, `PaySeller`, `ApproveReturn`) لیست شده بود. من یک مقدار چهارم `DisputeResolution.Reship` اضافه کردم: سفارش را بدون جابه‌جایی پول به `Shipped` با مهلت تحویل تازه برمی‌گرداند — این دقیقاً سناریوی «کالا گم/خراب نشده، فقط تلاش تحویل باید تکرار شود» را می‌پوشاند. تست `test_resolveDispute_reship_resetsToShippedWithoutMovingFunds` این را کامل تأیید می‌کند.

### یک تصمیم طراحی که باید بدانید: چرا state جدا برای `Returned` نساختم
سند در enum رسمی بخش ۳ فقط `Returning` را لیست کرده (نه `Returned`)، اما در فلوی بخش ۲۰ و دیاگرام بخش ۳۰ عبارت «Returned» هم به‌عنوان یک گام میانی ظاهر می‌شود. چون enum رسمی صراحتاً به‌عنوان کد داده شده و سند تأکید دارد «state machine باید کوچک و پایدار بماند»، من `confirmReturnReceived` را طوری طراحی کردم که مستقیماً `Returning → Refunded` برود؛ خودِ فراخوانی توسط اوراکل دقیقاً همان «بسته فیزیکاً به فروشنده رسید» را تصدیق می‌کند و دیگر اقدام آن‌چینی جداگانه‌ای لازم ندارد، پس یک state تمام‌عیار `Returned` فقط تکرار بی‌فایده‌ی `Refunded` می‌بود. اگر ترجیح می‌دهید این دو مرحله را واقعاً جدا کنید (مثلاً برای ثبت رسمی‌تر لاگ)، به‌راحتی می‌شود یک state هشتم اضافه کرد — به من بگویید تا انجامش بدهم.

---

## 2. مهم‌ترین تغییر معماری: تأییدیه‌ی تحویل دیگر فقط «اوراکل صدا می‌زند» نیست

طبق بخش‌های ۹ تا ۱۱ سند، تفاوت اساسی نسبت به نسخه‌ی قبلی این‌جاست:

**قبلاً:** `deliveryOracle` تماس می‌گرفت با یک `bytes proof` دلخواه؛ اگر OTP بود، رشته‌ی OTP مستقیم داخل `proof` بود و آن‌چین هش می‌شد.

**حالا:** `confirmDelivery` یک struct کامل و **امضاشده با EIP-712** می‌خواهد:

```solidity
struct DeliveryAttestation {
    uint256 orderId;
    bytes32 shipmentIdHash;   // = keccak256(bytes(order.shipmentId))
    bytes32 otpCommitment;    // باید دقیقاً برابر order.deliveryOtpHash باشد
    bool delivered;
    uint256 nonce;            // باید دقیقاً برابر order.deliveryNonce باشد
    uint256 timestamp;
    uint256 chainId;
    address escrowContract;
}
```

این تصمیم دقیقاً سه الزام سند را هم‌زمان برآورده می‌کند:

1. **بخش ۹: «فروشنده هرگز کنترل تأیید تحویل را ندارد و خریدار هم مستقیم OTP خام تراکنش نمی‌زند.»** خریدار OTP را فقط در اپ می‌دهد؛ اپ همان مقدار commitment ذخیره‌شده در سفارش را دوباره می‌سازد و امضا می‌کند. پلین‌تکست OTP اصلاً وارد کالددیتا نمی‌شود.
2. **بخش ۱۰-۱۱: «attestation باید امضاشده و replay-resistant باشد، بسته به order/chain/contract و یک nonce.»** پیاده شده کامل: `nonce` باید دقیقاً برابر `deliveryNonce` فعلی سفارش باشد و بعد از مصرف یک بار افزایش پیدا می‌کند (`o.deliveryNonce += 1`)، `chainId` و `escrowContract` هم چک می‌شوند.
3. **جداسازی نقش `deliveryOracle` (کسی که تراکنش می‌فرستد) از `attestationSigner` (کسی که واقعاً امضا می‌کند).** یعنی حتی اگر آدرس اوراکل روی چین به هر دلیلی به‌خطر بیفتد، بدون کلید خصوصی `attestationSigner` نمی‌تواند یک attestation جعلی بسازد.

تست‌های `test_confirmDelivery_revertsOnWrongSigner`, `test_confirmDelivery_revertsOnWrongNonce`, `test_confirmDelivery_revertsOnShipmentIdMismatch`, `test_confirmDelivery_nonceIncrementsAndBlocksReplay` هر کدام یکی از این ویژگی‌ها را جدا امتحان می‌کنند.

### چطور در تست‌ها امضا می‌سازیم (به‌عنوان مرجع برای تیم بک‌اند/اوراکل شما)
```solidity
bytes32 digest = escrow.hashDeliveryAttestation(attestation); // خودِ قرارداد این هش را می‌سازد
(uint8 v, bytes32 r, bytes32 s) = vm.sign(attestationSignerPrivateKey, digest);
bytes memory signature = abi.encodePacked(r, s, v);
```
سرویس بک‌اند شما (فاز A نقشه‌راه فایل قبلی) دقیقاً همین کار را با `ethers.js`/`viem` با `signTypedData` انجام می‌دهد؛ تابع `hashDeliveryAttestation` روی قرارداد عمومی است تا بتوانید دقیقاً همان دایجست را آف‌چین بازتولید کنید.

---

## 3. جداول جدید: incident log

```solidity
mapping(uint256 => DeliveryIncident[]) public orderIncidents;
```

هیچ‌کدام از سناریوهای فیزیکی (خرابی پهباد، تصادف، آسیب، کالای اشتباه، رد بسته) state جدید نساخته‌اند — دقیقاً طبق بخش ۱۲ سند («Do not create `State.PackageDamaged`, `State.DroneFailed`, …»). هر رویداد یک رکورد `DeliveryIncident` می‌شود (نوع، گزارش‌دهنده، زمان، مرجع شواهد off-chain، و پرچم resolved) و سفارش فقط به `Disputed` می‌رود.

**دو مسیر گزارش‌دهی جدا (دقیقاً طبق بخش ۵ سند):**
- `reportDeliveryIncident` → فقط `deliveryOracle` (خرابی‌های عملیاتی که خودِ سیستم لجستیک تشخیص می‌دهد)
- `raiseDispute` → فقط `buyer` (چیزهایی که فقط خریدار می‌تواند ببیند: آسیب، کالای اشتباه، رد بسته)

هیچ‌کدام مستقیم پول جابه‌جا نمی‌کنند؛ فقط قفل می‌کنند تا `arbiter` تصمیم بگیرد. این دقیقاً الزام ۱۳ و ۱۴ از چک‌لیست امنیتی بخش ۲۹ سند است.

---

## 4. جدول کامل توابع (فقط چیزهایی که عوض/اضافه شدند)

| تابع | تغییر نسبت به نسخه‌ی قبل |
|---|---|
| `confirmDelivery` | امضای تابع کامل عوض شد: حالا `DeliveryAttestation` امضاشده می‌گیرد، نه `bytes proof` ساده |
| `reportDeliveryIncident` | **جدید** — فقط اوراکل، از `Shipped`/`OutForDelivery`/`Returning` |
| `raiseDispute` | امضا عوض شد: حالا `IncidentType` + `evidenceRef` می‌گیرد، نه یک `string reason` آزاد |
| `reportDeliveryTimeout` | **جدید** — خریدار می‌تواند بعد از انقضای `deliveryDeadline` بدون هیچ گزارشی از اوراکل، خودش دیسپیوت باز کند |
| `resolveDispute` | امضا عوض شد: به‌جای `bool payToSeller` حالا `enum DisputeResolution` چهارحالته می‌گیرد |
| `confirmReturnReceived` | **جدید** — فقط اوراکل، از `Returning`، مستقیم `Refunded` می‌کند |
| `hashDeliveryAttestation` | **جدید** — ابزار کمکی view برای امضای آف‌چین |
| `setAttestationSigner` | **جدید** — ادمین |
| `incidentCount` | **جدید** — view کمکی |

توابعی که **دست‌نخورده ماندند** چون با معماری جدید تناقضی نداشتند: `createOrder`, `fundOrder`, `shipOrder`, `markOutForDelivery`, `releaseFunds`, `autoRelease`, `reportNotShipped`, `refundOrder`, `cancelUnfundedOrder`.

---

## 5. چک‌لیست امنیتی بخش ۲۹ سند — وضعیت هرکدام

| # | الزام | وضعیت |
|---|---|---|
| ۱ | انتقال حالت‌های سخت‌گیرانه | ✅ `onlyState` modifier روی همه‌ی توابع |
| ۲ | کنترل دسترسی مبتنی بر نقش | ✅ buyer/seller/oracle/arbiter/owner جدا |
| ۳ | فقط اوراکل مجاز | ✅ `onlyDeliveryOracle` |
| ۴ | آربیتر جدا از اوراکل | ✅ اجباری در constructor و در setterها (`newOracle == arbiter` رد می‌شود) |
| ۵ | فروشنده کنترل تأیید تحویل ندارد | ✅ فقط اوراکل `confirmDelivery` را صدا می‌زند |
| ۶ | بدون OTP خام آن‌چین | ✅ فقط `otpCommitment` (هش) در attestation |
| ۷ | OTP مقیدشده به سفارش | ✅ `keccak256(otp, orderId, address(this))` |
| ۸ | ضد replay برای attestation | ✅ `deliveryNonce` + chainId + escrowContract |
| ۹ | ضد رفاند تکراری | ✅ `onlyState` می‌گذارد فقط یک‌بار از `Cancelled`/`Disputed` خارج شود |
| ۱۰ | ضد پرداخت تکراری فروشنده | ✅ همان مکانیزم state |
| ۱۱ | ضد reentrancy | ✅ `ReentrancyGuard` + تست واقعی با توکن مخرب |
| ۱۲ | انتقال امن ERC20 | ✅ `SafeERC20` همه‌جا |
| ۱۳ | بدون پرداخت خودکار وقتی تحویل شکست خورده | ✅ `autoRelease` فقط از `Delivered` |
| ۱۴ | بدون پرداخت خودکار حین دیسپیوت | ✅ دیسپیوت state را از `Delivered` خارج می‌کند، پس `autoRelease` دیگر شرطش برقرار نیست |
| ۱۵ | بدون تغییر سفارش‌های نامرتبط | ✅ همه‌ی توابع `orderId`-محورند؛ تست `test_resolveDispute_cannotTouchUnrelatedOrder` |
| ۱۶ | بدون برداشت دلخواه توسط آربیتر | ✅ `resolveDispute` فقط روی همان `orderId` و فقط به `buyer`/`seller` همان سفارش پول می‌فرستد |
| ۱۷ | بدون استفاده‌ی مجدد از attestation | ✅ نانس بعد از مصرف افزایش می‌یابد |
| ۱۸ | بدون استفاده‌ی مجدد OTP بین سفارش‌ها | ✅ هش به orderId باند است |

---

## 6. اجرا

```bash
forge install OpenZeppelin/openzeppelin-contracts
forge build
forge test -vv
```

نکته‌ی فنی سابق هنوز پابرجاست: چون `Order` استراکت بزرگی است (۱۳ فیلد)، `via_ir = true` در `foundry.toml` لازم است وگرنه گتر خودکار به خطای stack-too-deep می‌خورد.

### دیپلوی
```bash
export PRIVATE_KEY=...
export PAYMENT_TOKEN=0x...        # آدرس DOTO
export ARBITER=0x...              # باید با اوراکل فرق داشته باشد
export ATTESTATION_SIGNER=0x...   # کلید سرویس بک‌اند تحویل
forge script script/Deploy.s.sol:DeployDeliveryEscrow --rpc-url ... --broadcast
```

---

## 7. چیزی که هنوز باید در سمت شما (بک‌اند/اوراکل) ساخته شود

این فایل فقط قرارداد را کامل می‌کند؛ نقشه‌راه GPS/پهباد/اتصال off-chain که در تحویل قبلی نوشتم (سرویس امضاکننده‌ی attestation، ژئوفنس، ذخیره‌ی شواهد روی IPFS) بدون تغییر معتبر است — تنها فرقش این است که حالا دقیقاً می‌دانید سرویس بک‌اند باید چه ساختار داده‌ای (`DeliveryAttestation`) را امضا کند و کجای آن باید `otpCommitment` و `nonce` را از `orders(orderId)` بخواند.
