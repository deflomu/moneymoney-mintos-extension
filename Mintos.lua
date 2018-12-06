WebBanking {
    version = 1.4,
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
    local datePattern = "(%d+)%.(%d+)%.(%d+)"

    if string.sub(account.accountNumber, -1) == '1' then
        local html = HTML(connection:get("https://www.mintos.com/en/overview/"))

        local balance = tonumber(string.match(html:xpath('//*[@class="overview-box"][1]/div/table/tr[1]/td[2]'):text(), ".*%s(%d+%.%d+).*"))

        local transactions = {}
		local oneDay = (24*60*60)
        local oneMonth = 4*7*24*60*60


        local toDate = since + oneMonth

        while toDate <= os.time() do
            print("Getting transactions from " .. os.date("%d.%m.%Y", since) .. " to " .. os.date("%d.%m.%Y", toDate+oneDay))

            local list = JSON(connection:request("POST",
            "https://www.mintos.com/en/account-statement/list",
            "account_statement_filter[fromDate]=" .. os.date("%d.%m.%Y", since) .. "&account_statement_filter[toDate]=" .. os.date("%d.%m.%Y", toDate+oneDay) .. "",
            "application/x-www-form-urlencoded; charset=UTF-8; Accept:text/html")):dictionary()

			if list["data"]["summary"]["total"]>0 then
			for i, element in ipairs(list["data"]["summary"]["accountStatements"]) do
			
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

            since = toDate + oneDay
            toDate = toDate + oneMonth
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
    connection:get("https://www.mintos.com/")
    connection:get("https://www.mintos.com/en/logout")
    return nil
end
