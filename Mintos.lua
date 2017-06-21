WebBanking {
    version = 1.1,
    url = "https://www.mintos.com/",
    services = { "Mintos Account" }
}

local connection

function SupportsBank (protocol, bankCode)
    return protocol == ProtocolWebBanking and bankCode == "Mintos Account"
end

function InitializeSession (protocol, bankCode, username, username2, password, username3)
    connection = Connection() 
    local html = HTML(connection:get(url))
    local csrfToken = html:xpath("//*[@id='login-form']/input[@name='_csrf_token']"):val()

    content, charset, mimeType = connection:request("POST",
    "https://www.mintos.com/en/login/check",
    "_username=" .. username .. "&_password=" .. password .. "&_csrf_token=" .. csrfToken,
    "application/x-www-form-urlencoded; charset=UTF-8")

    if string.match(connection:getBaseURL(), 'login') then
        return LoginFailed
    end
end

function ListAccounts (knownAccounts)
    local html = HTML(connection:get("https://www.mintos.com/en/my-settings/"))
    local accountNumber = html:xpath("//*/table[contains(concat(' ', normalize-space(@class), ' '), ' js-investor-settings ')]/tr[1]/td[@class='data']"):text()

    local accounts = {}

    table.insert(accounts, {
        name = 'Available Funds',
        accountNumber = accountNumber .. '-1',
        currency = "EUR",
        type = AccountTypeGiro
    })

    table.insert(accounts, {
        name = 'Invested Funds',
        accountNumber = accountNumber .. '-2',
        currency = "EUR",
        portfolio = true,
        type = AccountTypePortfolio
    })

    return accounts
end

function RefreshAccount (account, since)
    local datePattern = "(%d+)%.(%d+)%.(%d+).*%s(%d+):(%d+)"

    if string.sub(account.accountNumber, -1) == '1' then
        local html = HTML(connection:get("https://www.mintos.com/en/overview/"))

        local balance = tonumber(string.match(html:xpath('//*[@class="overview-box"][1]/div/table/tr[1]/td[2]'):text(), ".*%s(%d+%.%d+).*"))

        local transactions = {}
        local oneMonth = 4*7*24*60*60

        local toDate = since + oneMonth
        while toDate < os.time() do

            print("Getting transactions from " .. os.date("%d.%m.%Y", since) .. " to " .. os.date("%d.%m.%Y", toDate))

            local list = HTML(connection:request("POST",
            "https://www.mintos.com/en/account-statement/list",
            "account_statement_filter[fromDate]=" .. os.date("%d.%m.%Y", since) .. "&account_statement_filter[toDate]=" .. os.date("%d.%m.%Y", toDate) .. "",
            "application/x-www-form-urlencoded; charset=UTF-8"))

            list:xpath('//*[@id="overview-details"]/table/tbody/tr[not(@class)]'):each(function (index, element)
                local dateString = element:xpath('.//*[@class="m-transaction-date"]'):attr('title')
                local day, month, year, hour, min = dateString:match(datePattern)

                local purpose = element:xpath('.//*[@class="m-transaction-details"]'):text()

                local amount = element:xpath('.//*[contains(concat(" ", normalize-space(@class), " "), " m-transaction-amount ")]'):text()

                local transaction = {
                    bookingDate = os.time({day=day,month=month,year=year,hour=hour,min=min}),
                    purpose = purpose,
                    amount = tonumber(amount)
                }
                table.insert(transactions, transaction)
            end)
            since = toDate - 24*60*60
            toDate = toDate + oneMonth
        end

        return {
            balance = balance,
            transactions = transactions
        }
    else

        local page = 1
        local total = 1000
        local showing = 0

        local securities = {}

        while showing < total do
            local list = HTML(connection:request("POST",
            "https://www.mintos.com/en/my-investments/list",
            "statuses%5B%5D=256&statuses%5B%5D=512&statuses%5B%5D=1024&statuses%5B%5D=2048&statuses%5B%5D=8192&statuses%5B%5D=16384&max_results=100&page=" .. page,
            "application/x-www-form-urlencoded; charset=UTF-8"))


            list:xpath('//*[@id="investor-investments-table"]/tbody/tr[not(contains(@class, "total-row"))]'):each(function (index, element)
                local dateOfPurchaseString = element:xpath('.//*[contains(concat(" ", normalize-space(@class), " "), " m-loan-issued ")]'):attr('title')
                local day, month, year, hour, min = dateOfPurchaseString:match(datePattern)

                local name = element:xpath('.//*[contains(concat(" ", normalize-space(@class), " "), " m-loan-id ")]'):text()
                local price = string.match(element:xpath('.//*[@data-m-label="Outstanding Principal"]'):text(), ".*%s(%d+%.%d+).*")

                local security = {
                    dateOfPurchase = os.time({day=day,month=month,year=year,hour=hour,min=min}),
                    name = name,
                    currency = 'EUR',
                    amount = tonumber(price)
                }
                table.insert(securities, security)
            end)

            showing = list:xpath('//*[@id="result-status"]/span[@class="to"]'):text()
            total = list:xpath('//*[@id="result-status"]/span[@class="total"]'):text()
            page = page + 1
        end

        return {securities = securities}
    end
end

function EndSession ()
    connection:get("https://www.mintos.com/")
    connection:get("https://www.mintos.com/en/logout")
    return nil
end
