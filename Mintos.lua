WebBanking {
    version = 1.5,
    url = "https://www.mintos.com/en/login",
    services = { "Mintos Account" }
}

MAX_STATEMENTS_PER_PAGE = 300
MINTOS_DATE_PATTERN = "(%d+)%.(%d+)%.(%d+)"

function SupportsBank (protocol, bankCode)
    return protocol == ProtocolWebBanking and bankCode == "Mintos Account"
end

local function loginWithPassword (username, password)
    local html = HTML(connection:get(url))
    local csrfToken = html:xpath("//input[@name='_csrf_token']"):val()

    -- content might be used to get CSRF token to send two factor code in
    -- sendTwoFactorCode
    content = connection:request("POST",
    "https://www.mintos.com/en/login/check",
    table.concat({
        "_username=" .. username,
        "_password=" .. password,
        "_csrf_token=" .. csrfToken
    }, "&"),
    "application/x-www-form-urlencoded; charset=UTF-8")

    if string.match(connection:getBaseURL(), "twofactor") then
        return {
            title = "Two-factor authentication",
            challenge = "Enter the two-factor authentication code provided by the Authenticator app.",
            label = "6-digit code"
        }
    end

    if string.match(connection:getBaseURL(), "login") then
        return LoginFailed
    end
end

local function sendTwoFactorCode (twoFactorCode)
    local html = HTML(content)
    local csrfToken = html:xpath("//input[@name='_csrf_token']"):val()

    connection:request("POST",
    "https://www.mintos.com/en/login/twofactor",
    table.concat({
        "_one_time_password=" .. code,
        "_csrf_token=" .. csrfToken
    }, "&"),
    "application/x-www-form-urlencoded; charset=UTF-8")

    if string.match(connection:getBaseURL(), "login") then
        return LoginFailed
    end
end

function InitializeSession2 (protocol, bankCode, step, credentials, interactive)
    connection = Connection()
    if step == 1 then
        local username = credentials[1]
        local password = credentials[2]
        loginWithPassword(username, password)
    elseif step == 2 then
        local twoFactorCode = credentials[1]
        sendTwoFactorCode(twoFactorCode)
    end
end

function ListAccounts (knownAccounts)
    local html = HTML(connection:get("https://www.mintos.com/en/my-settings/"))
    local accountNumber = html:xpath("//*/table[contains(concat(' ', normalize-space(@class), ' '), ' js-investor-settings ')]/tr[1]/td[@class='data']"):text()

    return {
        {
            name = "Available Funds",
            accountNumber = accountNumber .. "-1",
            currency = "EUR",
            type = AccountTypeGiro
        }, {
            name = "Invested Funds",
            accountNumber = accountNumber .. "-2",
            currency = "EUR",
            portfolio = true,
            type = AccountTypePortfolio
        }
    }
end

local function extractPurpose (text)
    -- remove all html tags
    text = string.gsub(text, "(%b<>)", "")
    -- add newline after transaction id
    text = string.gsub(text, " %- ", "\n", 1)
    return text
end

local function parseStatements (receivedStatements)
    for i, element in ipairs(receivedStatements) do
        local day, month, year = element["date"]:match(MINTOS_DATE_PATTERN)

        local purpose = element["details"]
        local amount = element["turnover"]

        local transaction = {
            bookingDate = os.time({day=day,month=month,year=year,hour=0,min=0}),
            purpose = extractPurpose(purpose),
            amount = tonumber(amount)
        }

        table.insert(transactions, transaction)
    end
end

local function getStatementsForPage (since, page)
    local json = JSON(connection:request("POST",
    "https://www.mintos.com/en/account-statement/page/",
    table.concat({
        "account_statement_filter[fromDate]=" .. os.date("%d.%m.%Y", since),
        "account_statement_filter[toDate]=" .. os.date("%d.%m.%Y", os.time()),
        "account_statement_filter[maxResults]=".. MAX_STATEMENTS_PER_PAGE,
        "account_statement_filter[currency]=978",
        "account_statement_filter[page]=" .. page
    }, "&"),
    "application/x-www-form-urlencoded; charset=UTF-8",
    {
        ["Accept"] = "application/json",
        ["x-requested-with"] = "XMLHttpRequest"
    })):dictionary()

    return json["data"]["accountStatements"]
end

local function refreshAvailableFunds (since)
    transactions = {}

    local json = JSON(connection:request("POST",
    "https://www.mintos.com/en/account-statement/list",
    table.concat({
        "account_statement_filter[fromDate]=" .. os.date("%d.%m.%Y", since),
        "account_statement_filter[toDate]=" .. os.date("%d.%m.%Y", os.time()),
        "account_statement_filter[maxResults]=".. MAX_STATEMENTS_PER_PAGE
    }, "&"),
    "application/x-www-form-urlencoded; charset=UTF-8",
    {
        ["Accept"] = "application/json",
    })):dictionary()

    local balance = json["data"]["summary"]["finalBalance"]
    local total = json["data"]["summary"]["total"]
    local page = 1

    print("Found " .. total .. " transactions in total")

    local receivedStatements = json["data"]["summary"]["accountStatements"]

    parseStatements(receivedStatements)

    local remaining = total - #receivedStatements

    print("Received " .. #receivedStatements .. " statements. " .. remaining .. " remaining")

    while remaining > 0 do
        page = page + 1
        receivedStatements = getStatementsForPage(since, page)

        if #receivedStatements == 0 then
            error("Received no more statements but " .. remaining .. " still missing.")
        end

        parseStatements(receivedStatements)
        remaining = remaining - #receivedStatements
        print("Received " .. #receivedStatements .. " statements. " .. remaining .. " remaining")
    end

    return {
        balance = balance,
        transactions = transactions
    }
end

local function refreshInvestedFunds (since)
    local page = 1
    local totalPages = 1000

    local securities = {}

    while page <= totalPages do
        local json = JSON(connection:request("POST",
        "https://www.mintos.com/en/my-investments/list",
        table.concat({
            "currency=978",
            "sort_order=DESC",
            "max_results=100", 
            "page=" .. page
        }, "&"),
        "application/x-www-form-urlencoded; charset=UTF-8",
        {
            ["Accept"] = "application/json",
        })):dictionary()

        for j, element in ipairs(json["data"]["result"]["investments"]) do
            local day, month, year = element["createdAt"]:match(MINTOS_DATE_PATTERN)

            local name = element["loan"]["identifier"]
            local price = element["amount"]
            local type = element["loan"]["type"]

            local security = {
                dateOfPurchase = os.time({day=day,month=month,year=year,hour=0,min=0}),
                name = type .. " - " .. name,
                currency = "EUR",
                amount = tonumber(price)
            }
            table.insert(securities, security)
        end

        totalPages = json["data"]["result"]["totalPages"]
        page = page + 1
    end

    return {
        securities = securities
    }
end

function RefreshAccount (account, since)
    if account.type == AccountTypeGiro then 
        return refreshAvailableFunds(since)
    else
        return refreshInvestedFunds(since)
    end
end

function EndSession ()
    local logoutLink = HTML(content):xpath("//a[contains(@class,'logout')]"):attr("href")
    connection:get(logoutLink)
    return nil
end

