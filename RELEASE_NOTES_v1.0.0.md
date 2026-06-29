# نسخه v1.0.0 - پایشگر پایداری دی‌ان‌اس هوشمند برای OpenWRT

## خلاصه نسخه
این نسخه اولین انتشار پایدار و سبک سیستم مسیریابی دی‌ان‌اس هوشمند (`dns-smart-routing`) بر مبنای میکرومدل دو وضعیتی است. این سیستم در زمان‌های ناپایداری دی‌ان‌اس عمومی، ترافیک درخواست‌های آدرس‌دهی روتر را بدون قطعی ارتباط به سمت یک دی‌ان‌اس محلی سوییچ می‌نماید.

## ویژگی‌ها
- پایش سلامت دی‌ان‌اس عمومی با استفاده از سرورهای عمومی `1.1.1.1` و `8.8.8.8`.
- مدل دو وضعیتی بسیار سبک (`NORMAL` و `FAILOVER`).
- سوییچ به وضعیت دی‌ان‌اس محلی پس از ثبت **۲ خطای متوالی** جهت پایداری شبکه.
- بازگشت فوری به وضعیت عادی تنها با ثبت **۱ پاسخ موفق**.
- فاقد هرگونه لاگ شلوغ، فیلترهای تأخیردار یا مصرف بالای منابع.
- وابستگی صرفاً به ابزار `jq` (بدون نیاز به netcat/nc).

## این پروژه چه کاری انجام نمی‌دهد
- ❌ **فیلترشکن، پروکسی یا VPN نیست** و ترافیک را تونل نمی‌کند.
- ❌ هیچ تغییری در فایروال یا جداول روتینگ شبکه ایجاد نمی‌کند.
- ❌ جایگزینی برای Passwall/Xray نیست.

## نصب سریع
شما می‌توانید فایل `.ipk` ضمیمه شده را دانلود کرده و با دستورات زیر روی روتر نصب کنید:

```bash
opkg update
opkg install jq
opkg install /tmp/dns-smart-routing_1.0.0.ipk
/etc/init.d/dns-smart-routing enable
/etc/init.d/dns-smart-routing start
```

---

## English Summary
`dns-smart-routing` is a lightweight OpenWRT package designed to switch upstreams for `dnsmasq` to a local secure DNS resolver when public DNS queries fail. It uses a minimal 2-state micro model with a 2-consecutive failure threshold and recovers in a single success check, depending only on `jq`. It does not proxy, tunnel, or modify routing/firewall rules.
