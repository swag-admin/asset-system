# 設備資產管理系統：安裝與交接說明

這是公司的設備資產管理系統，可以記錄資產、員工保管與借用、線上簽收單、設備照片，並有逾期提醒。

系統由兩個服務組成，兩個都不是 Google：

| 服務 | 用途 | 費用 |
|---|---|---|
| Supabase | 資料庫、員工登入、照片儲存 | 可先用免費方案；正式使用建議 Pro，約每月 25 美元 |
| GitHub Pages | 放網頁 | 免費 |

資料存在 PostgreSQL 資料庫，查詢有建索引，畫面也只載入看得到的資料。實測在 50,000 筆資產下，搜尋與捲動都在 0.2 秒內完成。

---

## 開始前：準備一個公司共用信箱

**這是最重要的一步。** Supabase、GitHub 和寄信服務都請用公司的共用信箱註冊，例如 `it@yourcompany.com` 或 `admin@yourcompany.com`，**不要用個人信箱**。這樣任何人離職，系統都不受影響，只要把帳號交接給下一位即可。

---

## 步驟 1：建立 Supabase 專案

1. 到 https://supabase.com ，用公司共用信箱註冊。
2. 系統會請你建立一個 Organization（組織），名稱填公司名稱即可。
3. 按 **New project**：
   - **Name**：`asset-system`
   - **Database Password**：設一組強密碼，並存到公司的密碼管理工具。
   - **Region**：選 **Northeast Asia (Tokyo)** 或 **Southeast Asia (Singapore)**，離台灣較近，速度較快。
4. 等待約 2 分鐘，讓專案建立完成。

## 步驟 2：建立資料庫

1. 在左側選單點 **SQL Editor**，再按 **New query**。
2. 打開本資料夾的 `supabase/schema.sql`，把全部內容複製貼上，然後按 **Run**。看到 `Success` 就完成了。
3. 再開一個新的 query，貼上下面這段，把 Email 換成**你自己的公司 Email**，然後按 Run：

```sql
insert into public.roles (email, role) values ('you@yourcompany.com', 'admin')
on conflict (email) do update set role = 'admin';
```

> 建議同時再加一位主管或同事當管理員，避免只有一個人能管理系統。把上面的 Email 換成他的，再執行一次即可。之後也可以在系統的「設定與權限」頁面直接新增。

## 步驟 3：取得連線資料

1. 左側選單點 **Project Settings**，再點 **API Keys**（有些版本叫 **Data API** 或 **API**）。
2. 記下這兩個值：
   - **Project URL**：長得像 `https://abcdefgh.supabase.co`
   - **anon public key**，或新版的 **Publishable key**：一長串文字
3. 打開本資料夾的 `config.js`，把這兩個值填進去：

```js
window.APP_CONFIG = {
  SUPABASE_URL: "https://abcdefgh.supabase.co",
  SUPABASE_ANON_KEY: "貼上 anon 或 publishable key",
  SLACK_LOGIN: false
};
```

> anon／publishable key 本來就是設計成公開的，放在網頁裡是安全的，資料權限由資料庫規則保護。
> **絕對不要**把 `service_role` 或 `secret` key 放進 config.js，那把鑰匙可以繞過所有權限。

## 步驟 4：設定寄信服務（必要）

員工登入時，系統會寄 6 位數驗證碼到他的信箱。Supabase 內建的寄信服務每小時只能寄 2 封，而且只寄給專案成員，所以**一定要換成公司自己的寄信服務**。

1. 準備一個 SMTP 寄信服務，以下擇一：
   - **公司信箱的 SMTP**：請 IT 或信箱管理員提供主機、連接埠、帳號、密碼。
   - **Resend、SendGrid、Mailgun 等寄信服務**：Resend 有免費額度，一樣用公司共用信箱註冊，並依指示驗證公司網域。
2. 在 Supabase 左側點 **Authentication**，再點 **Emails**（或 **SMTP Settings**），打開 **Enable Custom SMTP**，填入：
   - **Sender email**：例如 `noreply@yourcompany.com`
   - **Sender name**：`設備資產管理系統`
   - **Host**、**Port**、**Username**、**Password**：寄信服務提供的資料
3. 儲存。啟用自訂 SMTP 後，預設上限是每小時 30 封。員工人數多的話，到 **Authentication → Rate Limits** 把 email 上限調高，例如 200。
4. 如果寄信服務有「點擊追蹤」（link tracking）功能，請關掉，否則可能讓登入信失效。

## 步驟 5：把登入信改成中文驗證碼

1. 在 **Authentication → Emails → Templates**，選 **Magic Link**。
2. **Subject（主旨）** 改成：`設備資產管理系統登入驗證碼`
3. **Body（內容）** 整段換成：

```html
<p>你好，</p>
<p>你的設備資產管理系統登入驗證碼是：</p>
<p style="font-size:28px;font-weight:bold;letter-spacing:6px">{{ .Token }}</p>
<p>請回到系統畫面輸入這組驗證碼。驗證碼 1 小時內有效，請勿提供給他人。</p>
<p>如果這不是你本人操作，請忽略這封信。</p>
```

> 為什麼用驗證碼，而不是點連結登入？企業信箱的安全掃描常會先「點開」信裡的連結檢查，一次性的登入連結就會因此失效。輸入驗證碼不會有這個問題。

## 步驟 6：放上 GitHub

1. 到 https://github.com ，用公司共用信箱註冊。
2. 建立組織：點右上角頭像，選 **Your organizations → New organization**，選 **Free** 方案，名稱填公司英文名稱。
3. 在組織裡按 **New repository**：
   - **Repository name**：`asset-system`
   - 選 **Public**（原因見下方說明）
4. 進入 repository，按 **Add file → Upload files**，把這些檔案拖進去：`index.html`、`config.js`、`README.md`，以及 `supabase` 資料夾。然後按 **Commit changes**。
5. 到 repository 的 **Settings → Pages**：
   - **Source** 選 **Deploy from a branch**
   - **Branch** 選 `main`，資料夾選 `/ (root)`，按 **Save**。
6. 等 1～2 分鐘，頁面上方會顯示網址，例如 `https://yourcompany.github.io/asset-system/`。這就是系統網址。

> **Public 安全嗎？** 安全。公開的只是程式碼，裡面沒有任何密碼或公司資料。資料全部存在 Supabase，沒被開通的人就算拿到網址也看不到任何內容。
> 若公司規定程式碼不能公開，GitHub 私人 repository 要用 GitHub Pages 需付費方案，也可以改放 Cloudflare Pages、Netlify 等其他免費託管服務。

## 步驟 7：告訴 Supabase 系統網址

1. 回到 Supabase，點 **Authentication → URL Configuration**。
2. **Site URL** 填入步驟 6 的系統網址。
3. **Redirect URLs** 按 **Add URL**，同樣填入系統網址。
4. 儲存。

## 步驟 8：第一次登入與匯入資料

1. 打開系統網址，輸入你在步驟 2 設定的 Email，按「寄送驗證碼」，再到信箱收驗證碼並輸入。
2. 到 **設定與權限**，填入公司名稱，並確認系統網址正確（Slack 通知會附上這個網址）。
3. **匯入員工**：到「員工」頁按「匯入 CSV」。
4. **匯入資產**：到「資產總覽」按「匯入 CSV」。請先匯入員工，資產才能對應到保管人。

### CSV 欄位格式

第一列必須是欄位名稱，順序可以不同，沒有的欄位可以省略。

**員工：** `員工編號`（必填）、`姓名`、`部門`、`Email`、`Slack ID`、`在職`（填「是」或「否」）

**資產：** `資產編號`（必填）、`名稱`、`類別`、`品牌`、`型號`、`序號`、`作業系統`、`狀態`、`預計歸還`、`保管人員工編號`、`存放位置`、`購入日期`、`保固到期`、`購入金額`、`備註`

- **狀態**：填中文，例如「在庫可用」「使用中」「借用中」「維修中」「遺失」「已報廢」。
- **日期**：格式為 `2026-10-15` 或 `2026/10/15`。
- **重複匯入**：資產編號或員工編號相同的資料會被更新，不會重複建立。

### 從 Claude 版本搬過來

1. 在舊系統的「設定」頁，下載「員工 CSV」與「資產 CSV」。
2. 在新系統先匯入員工，再匯入資產。欄位名稱兩邊一致，可以直接使用。
3. 照片與舊的線上簽名不會跟著搬過來。已簽收的單據，建議先在舊系統逐張下載存檔。

---

## 權限怎麼運作

所有權限都在資料庫層級強制執行，不只是隱藏按鈕。

| 身分 | 怎麼開通 | 可以做什麼 |
|---|---|---|
| 資產管理員 | 加在「設定與權限」的管理員名單 | 新增、修改、刪除資產與員工，上傳照片，產生與作廢簽收單，匯入匯出 |
| 唯讀 | 加在「設定與權限」的管理員名單 | 查看所有資料，不能修改 |
| 員工 | 員工資料填入公司 Email | 只看得到自己名下的設備與簽收單，只能簽自己的單 |

另外還有幾道保護：

- 員工無法代替他人簽名，管理員也無法偽造或修改員工的簽名。
- 已線上簽收的單據不能再修改；要更正，必須作廢後重新建立。
- 員工改為「已離職」後，就無法再登入。
- 系統至少會保留一位管理員，避免所有人都被鎖在門外。

---

## 管理者換人時的交接清單

1. **系統管理員**：在「設定與權限」**先加入**新管理者的 Email，**再移除**舊管理者。
2. **Supabase**：到 **Organization Settings → Team**，邀請新管理者加入並設為 **Owner**，確認他能登入後，再移除舊管理者。
3. **GitHub**：到組織的 **People**，邀請新管理者並設為 **Owner**，再移除舊管理者。
4. **寄信服務**：依服務的方式，把新管理者加入帳號，或把公司共用信箱的密碼交接給他。
5. **資料庫密碼**：步驟 1 設定的資料庫密碼，要在公司的密碼管理工具中交接。
6. **離職者本人**：如果他也在員工資料中，把他改為「已離職」。

只要這些帳號都是用公司名義建立的，換人不會影響系統運作，資料也完全不受影響。

---

## 備份

- **系統內建：** 「設定與權限」頁的 **下載完整備份** 會產生一個 JSON 檔，包含所有資產、員工、異動紀錄、簽收單與簽名，以及維修紀錄與使用紀錄。**建議每月下載一次**，存到公司的雲端硬碟。
- **Supabase Pro 方案：** 每天自動備份，保留 7 天；免費方案沒有可下載的資料庫備份。

## 費用說明

- **Supabase 免費方案：** 可以先用來試。但連續 7 天沒有使用，專案會被暫停，需要登入 Supabase 手動恢復，而且沒有自動備份。
- **Supabase Pro 方案：** 約每月 25 美元，不會因閒置而暫停，並有每日備份。**正式使用建議升級。**
- **GitHub Pages：** 免費。

費用與額度可能調整，請以 Supabase 官網公告為準。

---

## 更新系統程式

之後如果要更新功能，只需要在 GitHub 上換掉 `index.html`，**不要覆蓋 `config.js`**。若更新附帶新的 `schema.sql`，到 Supabase SQL Editor 重新執行一次即可，重複執行不會影響現有資料。

### 2026-10 更新：維修紀錄、使用紀錄、折舊與殘值

這次更新新增以下功能：

- **採購資訊：** 資產多了「供應商／購買通路」「採購人」「發票／採購單號」。
- **維修紀錄：** 新的「維修紀錄」頁。報修時設備自動改為「維修中」，完成後自動恢復成送修前的狀態與保管人；處理結果選「無法修復，報廢」時，設備會改為「已報廢」。
- **使用紀錄：** 每次保管人變動，系統自動記下使用者與起訖日期；簽收單簽回後會補上單號。可以在資產詳細頁看到歷任使用者，在員工頁看到他過去用過的設備。
- **折舊與殘值：** 依「購入金額、購入日期、耐用年數」自動計算目前帳面價值，每天更新。規則在「設定與權限 → 折舊設定」調整，資產總覽可匯出「價值報表 CSV」。

安裝步驟（依序進行）：

1. 先到「設定與權限」下載一次**完整備份**。
2. 打開 Supabase 的 **SQL Editor**，貼上 `supabase/update-2026-10-repairs-depreciation.sql` 的全部內容，按 **Run**，看到 `Success` 即完成。這個檔案只會新增欄位與資料表，不會修改或刪除既有資料，重複執行也安全。
3. 到 GitHub 用 **Add file → Upload files** 上傳新的 `index.html`（取代舊檔）和 `supabase/update-2026-10-repairs-depreciation.sql`。**不要覆蓋 `config.js`**。約 1 分鐘後網站會自動更新。
4. 重新整理系統頁面，到「設定與權限 → 折舊設定」確認耐用年數與殘值算法。**預設是電腦設備 3 年、殘值＝成本 ÷（耐用年數＋1），請先與會計確認。**
5. 補齊資產的「購入金額」與「購入日期」，帳面價值才算得出來。資產很多時，可以先「匯出 CSV」，在 Excel 補好後再「匯入 CSV」。

注意：使用紀錄從執行 SQL 當天開始記錄，目前有保管人的設備會以「領用日」（沒有領用日則以最後更新日）作為第一筆的開始日。更早的歷史仍可在每台設備的「異動紀錄」查到。

新安裝的系統：先執行 `schema.sql`，再執行 `update-2026-10-repairs-depreciation.sql`。

## 選用：用 Slack 登入

如果希望員工直接用 Slack 帳號登入：

1. 到 https://api.slack.com/apps 建立一個 App。在 **OAuth & Permissions** 的 Redirect URLs 加入 `https://你的專案.supabase.co/auth/v1/callback`。
2. 在 Supabase 的 **Authentication → Providers**，找到 **Slack (OIDC)** 並啟用，填入 Slack App 的 Client ID 與 Client Secret。
3. 把 `config.js` 的 `SLACK_LOGIN` 改成 `true`，然後重新上傳到 GitHub。

員工的 Slack 帳號 Email 必須和員工資料裡的 Email 相同，才能對應到本人。

---

## 常見問題

**收不到驗證碼信？**
先看垃圾郵件匣。再確認步驟 4 的 SMTP 設定正確，可以到 Supabase 的 **Logs → Auth** 查看寄信紀錄與錯誤訊息。

**登入後顯示「尚未開通」？**
這個 Email 不在管理員名單中，也沒有對應到在職員工。請在員工資料填入他的 Email，並確認拼字一致。

**顯示「寄信太頻繁」？**
到 **Authentication → Rate Limits** 調高 email 上限。

**系統打不開，或顯示無法連線？**
如果是免費方案，專案可能因為閒置 7 天被暫停了。登入 Supabase，在專案頁按 **Restore** 即可恢復。
