WebBanking {
    version = 1.5,
    url = "https://www.mintos.com/en/login",
    services = { "Mintos Account" }
}

local connection
local content

local oneDay = 24 * 60* 60
local maxStatementsOnPage = 300

local datePattern = "(%d+)%.(%d+)%.(%d+)"
local transactions

function SupportsBank (protocol, bankCode)
    return protocol == ProtocolWebBanking and bankCode == "Mintos Account"
end

function InitializeSession2 (protocol, bankCode, step, credentials, interactive)
    if step == 1 then
        connection = Connection()
        local html = HTML(connection:get(url))
        local csrfToken = html:xpath("//input[@name='_csrf_token']"):val()
        local username = credentials[1]
        local password = credentials[2]

        content = connection:request("POST",
        "https://www.mintos.com/en/login/check",
        "_username=" .. username .. "&_password=" .. password .. "&_csrf_token=" .. csrfToken,
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
    elseif step == 2 then
        local html = HTML(content)
        local csrfToken = html:xpath("//input[@name='_csrf_token']"):val()
        local code = credentials[1]

        connection:request("POST",
        "https://www.mintos.com/en/login/twofactor",
        "_one_time_password=" .. code .. "&_csrf_token=" .. csrfToken,
        "application/x-www-form-urlencoded; charset=UTF-8")

        if string.match(connection:getBaseURL(), "login") then
            return LoginFailed
        end
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

function ParseStatements (receivedStatements)
    if #receivedStatements > 0 then
        for i, element in ipairs(receivedStatements) do
            local transaction = ParseStatements(element)

            local dateString = element["date"]
            local day, month, year = dateString:match(datePattern)

            local purpose = element["details"]
            local amount = element["turnover"]

            local transaction = {
                bookingDate = os.time({day=day,month=month,year=year,hour=0,min=0}),
                purpose = StripHtml(purpose),
                amount = tonumber(amount)
            }

            table.insert(transactions, transaction)
        end
    end
end

function GetStatementsForPage (since, page)
    local list = JSON(connection:request("POST",
    "https://www.mintos.com/en/account-statement/page/",
    "account_statement_filter[fromDate]=" .. os.date("%d.%m.%Y", since) .. "&account_statement_filter[toDate]=" .. os.date("%d.%m.%Y", os.time()) .. "&account_statement_filter[maxResults]=".. maxStatementsOnPage .. "&account_statement_filter[currency]=978&account_statement_filter[page]=" .. page,
    "application/x-www-form-urlencoded; charset=UTF-8",
    {
        ["x-requested-with"] = "XMLHttpRequest"
    })):dictionary()

    return list["data"]["accountStatements"]

end

function RefreshAccount (account, since)

    if string.sub(account.accountNumber, -1) == "1" then
        transactions = {}

        local list = JSON(connection:request("POST",
        "https://www.mintos.com/en/account-statement/list",
        "account_statement_filter[fromDate]=" .. os.date("%d.%m.%Y", since) .. "&account_statement_filter[toDate]=" .. os.date("%d.%m.%Y", os.time()) .. "&account_statement_filter[maxResults]=".. maxStatementsOnPage,
        "application/x-www-form-urlencoded; charset=UTF-8")):dictionary()

        local balance = list["data"]["summary"]["finalBalance"]

        local total = list["data"]["summary"]["total"]
        local page = 1

        print("Found " .. total .. " transactions in total")

        local receivedStatements = list["data"]["summary"]["accountStatements"]

        ParseStatements(receivedStatements)

        local remaining = total - #receivedStatements

        print("Received " .. #receivedStatements .. " statements. " .. remaining .. " remaining")

        while remaining > 0 do
            page = page + 1
            receivedStatements = GetStatementsForPage(since, page)
            ParseStatements(receivedStatements)
            remaining = remaining - #receivedStatements
            print("Received " .. #receivedStatements .. " statements. " .. remaining .. " remaining")
        end

        return {
            balance = balance,
            transactions = transactions
        }
    else
        local page = 1
        local total = 1000

        local securities = {}

        while page <= total do
            local list = JSON(connection:request("POST",
            "https://www.mintos.com/en/my-investments/list",
            "currency=978&sort_order=DESC&max_results=100&page=" .. page,
            "application/x-www-form-urlencoded; charset=UTF-8")):dictionary()

            for j, element in ipairs(list["data"]["result"]["investments"]) do
                local dateOfPurchaseString = element["createdAt"]
                local day, month, year, hour, min = dateOfPurchaseString:match(datePattern)

                local name = element["loan"]["identifier"]
                local price = element["amount"]
                local type = element["loan"]["type"]

                local security = {
                    dateOfPurchase = os.time({day=day,month=month,year=year,hour=hour,min=min}),
                    name = type .. " - " .. name,
                    currency = 'EUR',
                    amount = tonumber(price)
                }
                table.insert(securities, security)
            end

            total = list["data"]["result"]["totalPages"]
            page = list["data"]["result"]["pagination"]["currentPage"] + 1
        end

        return {securities = securities}
    end
end

function StripHtml (t)
    local cleaner = {
        { "&amp;", "&" }, -- decode ampersands
        { "&#151;", "-" }, -- em dash
        { "&#146;", "'" }, -- right single quote
        { "&#147;", "\"" }, -- left double quote
        { "&#148;", "\"" }, -- right double quote
        { "&#150;", "-" }, -- en dash
        { "&#160;", " " }, -- non-breaking space
        { "<br ?/?>", "\n" }, -- all <br> tags whether terminated or not (<br> <br/> <br />) become new lines
        { "</p>", "\n" }, -- ends of paragraphs become new lines
        { "(%b<>)", "" }, -- all other html elements are completely removed (must be done last)
        { "\r", "\n" }, -- return carriage become new lines
        { "[\n\n]+", "\n" }, -- reduce all multiple new lines with a single new line
        { "^\n*", "" }, -- trim new lines from the start...
        { "\n*$", "" }, -- ... and end
    }

    -- clean html from the string
    for i=1, #cleaner do
        local cleans = cleaner[i]
        t = string.gsub( t, cleans[1], cleans[2] )
    end

    return t
end

function EndSession ()
    local logoutLink = HTML(content):xpath("//a[contains(@class,'logout')]"):attr("href")
    connection:get(logoutLink)
    return nil
end
