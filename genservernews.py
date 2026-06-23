#!/usr/bin/env python3
# -*- coding: utf-8 -*-

import datetime
import logging
import re
import xml
import xml.dom
import xml.dom.minidom

import utils

"""
Generate HTML Fragment about latest server news.
"""

SERVERNEWS_FEED = ""
SERVERNEWS_MAX_NUM = 3


def getServerNews(
    glob_logger: logging.Logger = None, feed: str = None, max_num: int = None
) -> list:
    """
    return list of NewsRecord object.

    Timeout is set to 20 seconds.
    """

    logger = glob_logger or logging.getLogger()
    feed = SERVERNEWS_FEED if feed is None else feed
    max_num = SERVERNEWS_MAX_NUM if max_num is None else max_num
    if not feed:
        return []

    def parseFeedData(text):
        """
        Will return proper HTML String by input.
        """
        class NewsRecord():
            def __init__(self, item):
                """Only The most useful data are picked for now."""
                self.title = item.getElementsByTagName('title')[0].firstChild.nodeValue
                self.link = item.getElementsByTagName('link')[0].getAttribute('href')
                self.date = datetime.datetime.fromisoformat(
                    item.getElementsByTagName('published')[0].firstChild.nodeValue
                )
                self.date_str = self.date.strftime("%Y-%m-%d")

                # if title does not already ends with a date marker
                if not re.search(r" \(\d{4}-\d{2}-\d{2}\)$", self.title):
                    self.title += f" ({self.date_str})"

        # impl = xml.dom.getDOMImplementation() # Not needed in parsing
        doc = xml.dom.minidom.parseString(text)
        current_num = 0
        for item in doc.getElementsByTagName('entry'):
            if (current_num >= max_num):
                break
            if item.getElementsByTagName("category")[0].getAttribute("term") != "mirrors":
                continue
            current_num += 1
            yield NewsRecord(item)

    logger.info('begin generation of ServerNews...')
    newslist = []
    try:
        resp = utils.get_resp_with_timeout(feed, logger=logger)
        if resp is None:
            return newslist
        newslist = list(parseFeedData(resp.text))
        logger.info("newslist generation successful, size is {}.".format(len(newslist)))
    except Exception as e:
        logger.error('unknown exception caught: "{}".'.format(str(e)))
    return newslist


if __name__ == "__main__":
    for i in getServerNews():
        print(i.title, i.link)

# vim:set ts=8 sw=4 tw=0 et:
