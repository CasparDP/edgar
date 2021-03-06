library(dplyr, warn.conflicts = FALSE)
library(DBI)

pg <- dbConnect(RPostgres::Postgres())
rs <- dbExecute(pg, "SET search_path TO edgar")

cusip_cik <- tbl(pg, "cusip_cik")

# These are the valid 9-digit CUSIPs (based on check digit)
valid_cusip9s <-
    cusip_cik %>%
    filter(nchar(cusip) == 9) %>%
    filter(substr(cusip, 9, 9) == as.character(check_digit)) %>%
    compute()

# Flag all filings that contain multiple valid 9-digit CUSIPs
# that do not share 6-digit CUSIPs. We need to delete these.
mult_cusips <-
    valid_cusip9s %>%
    mutate(cusip6 = substr(cusip, 1L, 6L)) %>%
    select(file_name, cusip6) %>%
    distinct() %>%
    group_by(file_name) %>%
    summarize(n_cusips = n()) %>%
    filter(n_cusips > 1) %>%
    ungroup() %>%
    select(file_name) %>%
    compute()

bad_cusips <-
    cusip_cik %>%
    filter(nchar(cusip)==9L) %>%
    mutate(bad_cusip = case_when(! right(cusip, 1L) %~% '[0-9]' ~ TRUE,
                                 as.integer(right(cusip, 1L)) != check_digit ~ TRUE,
                                 TRUE ~ FALSE)) %>%
    filter(bad_cusip) %>%
    select(-bad_cusip) %>%
    compute()

dbExecute(pg, "DROP TABLE IF EXISTS cusip_cik_test")

# This code takes only the valid 9-digit CUSIPs from the filings
# that contains then adds on the existing data from all other filings.
cusip_cik_test <-
    cusip_cik %>%
    semi_join(valid_cusip9s, by = c("file_name", "cusip")) %>%
    union_all(
        cusip_cik %>%
            anti_join(valid_cusip9s, by = "file_name")) %>%
    anti_join(mult_cusips) %>% anti_join(bad_cusips) %>%
    compute(name = "cusip_cik_test", temporary = FALSE)

rs <- dbExecute(pg, "ALTER TABLE cusip_cik_test OWNER TO edgar")

dbDisconnect(pg)
